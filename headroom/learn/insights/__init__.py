"""Offline savings estimator for `headroom learn --insights`.

Estimates how much Headroom would have saved over historical agent logs by
running real content-type detection and modeling each savings mechanism —
without ever compressing or storing anything.
"""

from __future__ import annotations

from .estimator import InsightsEstimator
from .models import (
    InsightsConfig,
    InsightsReport,
    MechanismSavings,
    Pricing,
)
from .pricing import resolve_pricing

__all__ = [
    "InsightsConfig",
    "InsightsEstimator",
    "InsightsReport",
    "MechanismSavings",
    "Pricing",
    "resolve_pricing",
]
