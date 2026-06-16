"""Data models and configuration for the `headroom learn --insights` estimator.

Everything tunable lives in :class:`InsightsConfig` (no hardcodes in the
estimator). The compression shrink-ratios are *priors* — calibrated once on a
sample via the exact ``--replay`` path, then reused. They are not magic
constants baked into logic.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ...transforms.content_detector import ContentType

# Confidence tiers attached to each mechanism so the report never blends a
# guess into the headline as if it were exact.
CONF_MEASURED = "measured"  # near-exact (CCR exact-hash dedup)
CONF_CALIBRATED = "calibrated"  # compressor ratios calibrated on a sample
CONF_RANGE = "range"  # RTK published 60-90% band
CONF_MODELED = "modeled"  # Serena counterfactual (unvalidated assumption)


# Per-content-type compression model: ContentType -> (strategy label, kept ratio).
# Mirrors ContentRouter._strategy_from_detection_type (content_router.py:1599).
# `kept` is the fraction of tokens RETAINED after compression; savings = 1 - kept.
def _default_content_type_ratios() -> dict[ContentType, tuple[str, float]]:
    return {
        ContentType.JSON_ARRAY: ("smart_crusher", 0.40),
        ContentType.BUILD_OUTPUT: ("log", 0.30),
        ContentType.SEARCH_RESULTS: ("search", 0.35),
        ContentType.GIT_DIFF: ("diff", 0.50),
        ContentType.HTML: ("html", 0.40),
        ContentType.SOURCE_CODE: ("code_aware", 0.75),
        ContentType.PLAIN_TEXT: ("text", 0.85),
    }


# RTK-filtered command binaries, taken verbatim from the rtk-instructions block
# in headroom/cli/wrap.py (RTK_INSTRUCTIONS_BLOCK).
def _default_rtk_allowlist() -> frozenset[str]:
    return frozenset(
        {
            "git",
            "ls",
            "read",
            "grep",
            "find",
            "diff",
            "pytest",
            "cargo",
            "tsc",
            "lint",
            "prettier",
            "mypy",
            "ruff",
            "gh",
            "docker",
            "kubectl",
            "pip",
            "pnpm",
            "npm",
        }
    )


def _default_edit_tools() -> frozenset[str]:
    return frozenset({"Edit", "edit", "Write", "write", "MultiEdit", "multiedit", "NotebookEdit"})


@dataclass
class InsightsConfig:
    """All knobs for the offline estimator. Defaults are conservative priors."""

    # Only content above this token floor is considered (matches the router's
    # min_tokens_to_compress default of 50).
    size_floor_tokens: int = 50
    skip_errors: bool = True

    # Compressor mechanism (calibrated).
    content_type_ratios: dict[ContentType, tuple[str, float]] = field(
        default_factory=_default_content_type_ratios
    )

    # RTK mechanism (range / band).
    rtk_allowlist: frozenset[str] = field(default_factory=_default_rtk_allowlist)
    rtk_band_low: float = 0.60
    rtk_band_high: float = 0.90
    rtk_band_point: float = 0.75  # midpoint credited to the headline

    # Serena mechanism (modeled counterfactual).
    serena_symbol_fraction: float = 0.30  # fraction a symbol-level read would retain
    serena_require_later_edit: bool = True  # only count full reads of files later edited
    edit_tool_names: frozenset[str] = field(default_factory=_default_edit_tools)

    # CCR mechanism (measured). NET = gross x (1 - retrieve_back_rate).
    ccr_retrieve_back_rate: float = 0.20  # assumed share re-fetched via headroom_retrieve

    # Cache-read price multiplier when the model's explicit cache price is unknown
    # (Anthropic/OpenAI prompt-cache reads bill at ~0.1x input).
    cache_read_price_multiplier: float = 0.10


@dataclass
class Pricing:
    """Per-1M-token USD prices used to value saved tokens."""

    input_per_1m: float
    cache_read_per_1m: float


@dataclass
class MechanismSavings:
    """Savings attributed to one mechanism, with its confidence tier."""

    name: str
    saved_tokens: int  # headline contribution (NET for CCR)
    confidence: str
    detail: str = ""
    gross_tokens: int | None = None  # CCR only: gross before retrieve-back


@dataclass
class InsightsReport:
    """Aggregate result of an insights estimation run."""

    model: str
    n_sessions: int
    n_tool_calls: int
    tool_output_tokens: int  # total tool-output volume examined (the % denominator)
    saved_tokens: int
    mechanisms: dict[str, MechanismSavings]
    cache_read_fraction: float
    gross_usd: float | None = None
    cache_honest_usd: float | None = None
    sessions_by_source: dict[str, int] = field(
        default_factory=dict
    )  # main/subagent/workflow counts

    @property
    def savings_pct(self) -> float:
        if self.tool_output_tokens <= 0:
            return 0.0
        return self.saved_tokens / self.tool_output_tokens
