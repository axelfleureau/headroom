"""Render an :class:`InsightsReport` to human text, JSON, or CSV.

Output conventions mirror ``headroom perf`` (text + ``--format json|csv``) so
insights plugs into the same dashboards and tooling.
"""

from __future__ import annotations

import csv
import io

from .models import InsightsReport

# Stable display order: most-defensible mechanism first.
_ORDER = ["compressor", "ccr", "rtk", "serena"]


def format_text(report: InsightsReport) -> str:
    lines: list[str] = []
    lines.append("Headroom Insights — estimated savings (nothing was compressed)")
    lines.append("=" * 64)
    source_line = ""
    if report.sessions_by_source:
        parts = [f"{count} {name}" for name, count in sorted(report.sessions_by_source.items())]
        source_line = f" ({', '.join(parts)})"
    lines.append(
        f"Model: {report.model}   Sessions: {report.n_sessions}{source_line}   "
        f"Tool calls: {report.n_tool_calls:,}"
    )
    lines.append("")
    lines.append(f"Tool output examined: {report.tool_output_tokens:,} tokens")
    lines.append(
        f"Headroom would remove ~{report.saved_tokens:,} tokens "
        f"({report.savings_pct:.1%} of tool output)"
    )
    if report.cache_honest_usd is not None and report.gross_usd is not None:
        lines.append(f"  Cache-honest savings: ${report.cache_honest_usd:,.2f}")
        lines.append(
            f"  Gross potential:      ${report.gross_usd:,.2f}  "
            f"(if none were already prompt-cached)"
        )
    else:
        lines.append("  Cost estimate: unavailable (no pricing for this model)")
    lines.append(
        f"  (Your sessions billed input at {report.cache_read_fraction:.0%} prompt-cache reads.)"
    )
    lines.append("")
    lines.append("By mechanism:")
    for key in _ORDER:
        mech = report.mechanisms.get(key)
        if mech is None:
            continue
        extra = f" (gross {mech.gross_tokens:,})" if mech.gross_tokens is not None else ""
        lines.append(f"  {mech.name:<11} {mech.saved_tokens:>12,} tok  [{mech.confidence}]{extra}")
        if mech.detail:
            lines.append(f"              {mech.detail}")
    return "\n".join(lines)


def to_json(report: InsightsReport) -> dict:
    return {
        "model": report.model,
        "n_sessions": report.n_sessions,
        "sessions_by_source": report.sessions_by_source,
        "n_tool_calls": report.n_tool_calls,
        "tool_output_tokens": report.tool_output_tokens,
        "saved_tokens": report.saved_tokens,
        "savings_pct": report.savings_pct,
        "cache_read_fraction": report.cache_read_fraction,
        "gross_usd": report.gross_usd,
        "cache_honest_usd": report.cache_honest_usd,
        "mechanisms": {
            name: {
                "saved_tokens": mech.saved_tokens,
                "confidence": mech.confidence,
                "detail": mech.detail,
                "gross_tokens": mech.gross_tokens,
            }
            for name, mech in report.mechanisms.items()
        },
    }


def to_csv(report: InsightsReport) -> str:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["mechanism", "saved_tokens", "confidence", "gross_tokens"])
    for key in _ORDER:
        mech = report.mechanisms.get(key)
        if mech is None:
            continue
        writer.writerow([mech.name, mech.saved_tokens, mech.confidence, mech.gross_tokens or ""])
    writer.writerow(["TOTAL", report.saved_tokens, "", ""])
    return buf.getvalue()
