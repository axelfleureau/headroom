"""Offline savings estimator for `headroom learn --insights`.

One streaming pass over already-parsed sessions. For each tool output it runs
the REAL content-type detector to decide which compressor would handle it, then
ESTIMATES savings from a calibrated shrink-ratio — nothing is ever compressed or
stored. Four mechanisms are attributed with a single-primary rule so the same
content is never double-counted:

    repeat of earlier content  -> CCR (measured)
    else allowlisted Bash cmd  -> RTK (range)
    else full-file Read later edited -> Serena (modeled)
    else                       -> compressor (calibrated, via real detection)

Savings are counted once per piece of content (cache-honest by construction:
the prompt cache makes re-reads cheap, so we never multiply across turns).
"""

from __future__ import annotations

import hashlib
from collections.abc import Callable

from ...transforms.content_detector import ContentType, detect_content_type
from ..models import SessionData, ToolCall
from .models import (
    CONF_CALIBRATED,
    CONF_MEASURED,
    CONF_MODELED,
    CONF_RANGE,
    InsightsConfig,
    InsightsReport,
    MechanismSavings,
    Pricing,
)
from .pricing import resolve_pricing

_BASH_NAMES = ("Bash", "bash")
_READ_NAMES = ("Read", "read")


def _normalize(text: str) -> str:
    """Whitespace-stable form for content-hash dedup (exact-duplicate floor)."""
    return "\n".join(line.rstrip() for line in text.strip().splitlines())


def _content_hash(text: str) -> str:
    return hashlib.sha256(_normalize(text).encode("utf-8", "ignore")).hexdigest()[:24]


def _bash_binary(tc: ToolCall) -> str | None:
    """Leading executable name of a Bash command (basename, rtk-prefix aware)."""
    cmd = tc.input_data.get("command", "")
    if not isinstance(cmd, str):
        return None
    parts = cmd.strip().split()
    i = 0
    # Skip leading VAR=value environment assignments.
    while i < len(parts) and "=" in parts[i] and not parts[i].startswith("-"):
        i += 1
    if i >= len(parts):
        return None
    binary = parts[i].split("/")[-1]
    if binary == "rtk" and i + 1 < len(parts):
        binary = parts[i + 1].split("/")[-1]
    return binary or None


def _is_full_file_read(tc: ToolCall) -> bool:
    """A Read with no offset/limit reads the whole file (Serena would narrow it)."""
    return "offset" not in tc.input_data and "limit" not in tc.input_data


class InsightsEstimator:
    """Estimate how much Headroom would have saved over historical sessions."""

    def __init__(
        self,
        config: InsightsConfig | None = None,
        tokenizer=None,
        detect_fn: Callable[[str], ContentType] | None = None,
    ) -> None:
        self.config = config or InsightsConfig()
        self._tokenizer = tokenizer
        self._detect_fn = detect_fn or (lambda content: detect_content_type(content).content_type)

    def estimate(
        self,
        sessions: list[SessionData],
        model: str,
        pricing: Pricing | None = None,
    ) -> InsightsReport:
        cfg = self.config
        tok = self._tokenizer
        if tok is None:
            from ...tokenizers import get_tokenizer

            tok = get_tokenizer(model)

        mech_tokens = {"compressor": 0, "ccr": 0, "rtk": 0, "serena": 0}
        ccr_gross = 0
        n_tool_calls = 0
        considered_tokens = 0  # tool-output volume (counted once per call) = the % denominator
        total_input = 0
        total_cache_read = 0
        sessions_by_source: dict[str, int] = {}

        for session in sessions:
            total_input += session.total_input_tokens
            total_cache_read += session.total_cache_read_tokens
            sessions_by_source[session.source] = sessions_by_source.get(session.source, 0) + 1

            # Files edited anywhere in this session — the Serena signal that a
            # full read was wasteful (a symbol-level read would have sufficed).
            edited_files: set[str] = set()
            for tc in session.tool_calls:
                if tc.name in cfg.edit_tool_names:
                    fp = tc.input_data.get("file_path")
                    if fp:
                        edited_files.add(str(fp))

            seen_hashes: set[str] = set()  # CCR dedup is PER SESSION (store TTL is short)
            for tc in session.tool_calls:
                n_tool_calls += 1
                if cfg.skip_errors and tc.is_error:
                    continue
                content = tc.output
                if not content:
                    continue
                tokens = tok.count_text(content)
                considered_tokens += tokens  # every non-error tool output, before the floor
                if tokens < cfg.size_floor_tokens:
                    continue

                h = _content_hash(content)
                if h in seen_hashes:
                    # Repeat -> CCR only (never also compressor/RTK/Serena).
                    ccr_gross += tokens
                    mech_tokens["ccr"] += round(tokens * (1 - cfg.ccr_retrieve_back_rate))
                    continue
                seen_hashes.add(h)

                # First occurrence -> exactly one primary mechanism.
                binary = _bash_binary(tc) if tc.name in _BASH_NAMES else None
                if binary and binary in cfg.rtk_allowlist:
                    mech_tokens["rtk"] += round(tokens * cfg.rtk_band_point)
                elif (
                    tc.name in _READ_NAMES
                    and _is_full_file_read(tc)
                    and (
                        not cfg.serena_require_later_edit
                        or str(tc.input_data.get("file_path", "")) in edited_files
                    )
                ):
                    mech_tokens["serena"] += round(tokens * (1 - cfg.serena_symbol_fraction))
                else:
                    content_type = self._detect_fn(content)
                    _label, kept = cfg.content_type_ratios.get(content_type, ("text", 1.0))
                    saved = round(tokens * (1 - kept))
                    if saved > 0:
                        mech_tokens["compressor"] += saved

        mechanisms = self._build_mechanisms(mech_tokens, ccr_gross)
        saved_tokens = sum(mech_tokens.values())
        cache_fraction = total_cache_read / total_input if total_input > 0 else 0.0

        gross_usd, cache_honest_usd = self._price(saved_tokens, cache_fraction, model, pricing)

        return InsightsReport(
            model=model,
            n_sessions=len(sessions),
            n_tool_calls=n_tool_calls,
            tool_output_tokens=considered_tokens,
            saved_tokens=saved_tokens,
            mechanisms=mechanisms,
            cache_read_fraction=cache_fraction,
            gross_usd=gross_usd,
            cache_honest_usd=cache_honest_usd,
            sessions_by_source=sessions_by_source,
        )

    def _build_mechanisms(
        self, mech_tokens: dict[str, int], ccr_gross: int
    ) -> dict[str, MechanismSavings]:
        cfg = self.config
        out: dict[str, MechanismSavings] = {}
        if mech_tokens["compressor"] > 0:
            out["compressor"] = MechanismSavings(
                name="compressor",
                saved_tokens=mech_tokens["compressor"],
                confidence=CONF_CALIBRATED,
                detail="real detection + calibrated per-type shrink ratios",
            )
        if mech_tokens["ccr"] > 0:
            out["ccr"] = MechanismSavings(
                name="ccr",
                saved_tokens=mech_tokens["ccr"],
                confidence=CONF_MEASURED,
                detail=f"exact-duplicate dedup, net of {cfg.ccr_retrieve_back_rate:.0%} retrieve-back",
                gross_tokens=ccr_gross,
            )
        if mech_tokens["rtk"] > 0:
            out["rtk"] = MechanismSavings(
                name="rtk",
                saved_tokens=mech_tokens["rtk"],
                confidence=CONF_RANGE,
                detail=f"published {cfg.rtk_band_low:.0%}-{cfg.rtk_band_high:.0%} band, midpoint credited",
            )
        if mech_tokens["serena"] > 0:
            out["serena"] = MechanismSavings(
                name="serena",
                saved_tokens=mech_tokens["serena"],
                confidence=CONF_MODELED,
                detail=f"full-file reads later edited; assumes symbol read retains {cfg.serena_symbol_fraction:.0%}",
            )
        return out

    def _price(
        self,
        saved_tokens: int,
        cache_fraction: float,
        model: str,
        pricing: Pricing | None,
    ) -> tuple[float | None, float | None]:
        if pricing is None:
            pricing = resolve_pricing(model, self.config.cache_read_price_multiplier)
        if pricing is None:
            return None, None
        input_per_token = pricing.input_per_1m / 1_000_000
        cache_read_per_token = pricing.cache_read_per_1m / 1_000_000
        gross_usd = saved_tokens * input_per_token
        blended = input_per_token * (1 - cache_fraction) + cache_read_per_token * cache_fraction
        cache_honest_usd = saved_tokens * blended
        return gross_usd, cache_honest_usd
