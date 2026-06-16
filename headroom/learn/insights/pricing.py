"""Resolve per-token USD pricing for the insights estimator.

Reuses Headroom's existing LiteLLM-backed pricing database. Returns ``None``
when a model's price is unknown — the report then shows tokens only and says
pricing is unavailable, rather than silently inventing a dollar figure.
"""

from __future__ import annotations

import contextlib
import io
import logging

from .models import Pricing

logger = logging.getLogger(__name__)


def resolve_pricing(model: str, cache_read_multiplier: float = 0.10) -> Pricing | None:
    """Look up input + cache-read per-1M prices for *model*.

    Cache-read price uses the model's explicit prompt-cache price when LiteLLM
    has it, otherwise ``cache_read_multiplier`` x input (the standard ~0.1x).

    All LiteLLM access is wrapped in stdout/stderr redirection: LiteLLM prints
    provider-hint chatter on some lookups, which would corrupt ``--format json``.
    """
    # Discard any LiteLLM stdout/stderr chatter so machine output stays clean.
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        try:
            from ...pricing.litellm_pricing import (
                get_litellm_model_cost,
                get_model_pricing,
                resolve_litellm_model,
            )
        except ImportError:  # pragma: no cover - pricing module always present
            return None

        pricing = get_model_pricing(model)
        if pricing is None or not pricing.input_cost_per_1m:
            logger.debug("No pricing found for model %r", model)
            return None

        input_per_1m = pricing.input_cost_per_1m
        cache_read_per_1m = input_per_1m * cache_read_multiplier

        # Prefer the model's explicit cache-read price if LiteLLM exposes one.
        try:
            cost = get_litellm_model_cost()
            info = cost.get(resolve_litellm_model(model)) or cost.get(model)
            if info:
                explicit = info.get("cache_read_input_token_cost")
                if explicit:
                    cache_read_per_1m = explicit * 1_000_000
        except Exception:  # pragma: no cover - defensive only
            pass

    return Pricing(input_per_1m=input_per_1m, cache_read_per_1m=cache_read_per_1m)
