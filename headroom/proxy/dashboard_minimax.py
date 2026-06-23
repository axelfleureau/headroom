"""MiniMax-specific dashboard for Headroom Proxy.

Provides an aggregated view of all MiniMax traffic flowing through the
proxy — distinct from the generic ``/dashboard`` page, which mixes
MiniMax with Anthropic / OpenAI / Gemini.

The HTML is fully self-contained (CSS + vanilla JS embedded) so it
works regardless of the operator's CDN / static-file setup. Data is
fetched client-side from ``/stats`` and filtered by
``provider == "minimax"`` so we don't have to invent a new API surface.

Usage::

    from headroom.proxy.dashboard_minimax import get_minimax_dashboard_html

    @app.get("/dashboard/minimax", response_class=HTMLResponse)
    async def minimax_dashboard():
        return get_minimax_dashboard_html()
"""

from __future__ import annotations


def get_minimax_dashboard_html() -> str:
    """Return the MiniMax dashboard HTML."""
    return _MINIMAX_DASHBOARD_HTML


_HTML_HEAD = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>MiniMax Dashboard — Headroom</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  :root {
    --bg: #0b0d10;
    --panel: #14181d;
    --panel-2: #1a1f25;
    --border: #232932;
    --text: #e8e8e8;
    --text-dim: #9aa3ad;
    --accent: #6cb6ff;
    --accent-2: #ff7a59;
    --good: #4ade80;
    --warn: #facc15;
    --bad: #ef4444;
  }
  * { box-sizing: border-box; }
  html, body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, sans-serif; margin: 0; padding: 0; }
  body { padding: 28px 36px 60px; }
  header { display: flex; align-items: baseline; gap: 16px; margin-bottom: 28px; }
  h1 { font-size: 22px; font-weight: 600; letter-spacing: -0.02em; margin: 0; }
  .sub { color: var(--text-dim); font-size: 13px; }
  .pill { background: var(--panel-2); border: 1px solid var(--border); border-radius: 999px; padding: 2px 10px; font-size: 11px; color: var(--text-dim); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .pill.live::before { content: "●"; color: var(--good); margin-right: 6px; }
  .grid { display: grid; gap: 16px; }
  .grid.kpi { grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); margin-bottom: 20px; }
  .grid.cols-2 { grid-template-columns: 2fr 1fr; }
  .grid.cols-3 { grid-template-columns: 1fr 1fr 1fr; }
  .panel { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 18px 20px; }
  .panel h2 { font-size: 13px; font-weight: 500; color: var(--text-dim); margin: 0 0 12px; text-transform: uppercase; letter-spacing: 0.06em; }
  .kpi .v { font-size: 28px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .kpi .l { color: var(--text-dim); font-size: 12px; margin-top: 4px; }
  .kpi.delta-up .v { color: var(--good); }
  .kpi.delta-down .v { color: var(--bad); }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { padding: 8px 10px; text-align: left; border-bottom: 1px solid var(--border); }
  th { color: var(--text-dim); font-weight: 500; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  tr:hover td { background: rgba(255,255,255,0.02); }
  .tag { background: var(--panel-2); border: 1px solid var(--border); padding: 2px 8px; border-radius: 4px; font-size: 11px; font-family: ui-monospace, monospace; color: var(--text-dim); }
  .tag.thinking { color: var(--accent); border-color: rgba(108,182,255,0.3); }
  .tag.tool { color: var(--accent-2); border-color: rgba(255,122,89,0.3); }
  .bar { background: var(--panel-2); height: 6px; border-radius: 3px; overflow: hidden; }
  .bar > i { display: block; height: 100%; background: var(--accent); border-radius: 3px; }
  .small { color: var(--text-dim); font-size: 11px; }
  .empty { color: var(--text-dim); font-style: italic; text-align: center; padding: 24px; }
  .refresh-btn { background: var(--panel-2); border: 1px solid var(--border); color: var(--text); padding: 4px 12px; border-radius: 6px; font-size: 12px; cursor: pointer; font-family: inherit; }
  .refresh-btn:hover { background: var(--border); }
  footer { margin-top: 24px; color: var(--text-dim); font-size: 11px; text-align: right; }
  code { background: var(--panel-2); padding: 2px 6px; border-radius: 3px; font-size: 12px; color: var(--accent); }
</style>
</head>
<body>
<header>
  <h1>MiniMax <span class="sub">— proxy traffic</span></h1>
  <span class="pill live" id="live-pill">live</span>
  <span class="pill" id="upstream-pill">upstream: …</span>
  <span class="pill" id="last-update">never</span>
  <button class="refresh-btn" onclick="loadStats()">↻ refresh</button>
  <span class="sub" style="margin-left:auto">window: <select id="window-select" onchange="loadStats()" style="background: var(--panel-2); color: var(--text); border: 1px solid var(--border); border-radius: 6px; padding: 3px 8px; font-family: inherit; font-size: 12px;">
    <option value="session">display session</option>
    <option value="lifetime">lifetime (persistent)</option>
  </select></span>
</header>
"""

_BODY = """\
<div class="grid kpi">
  <div class="panel kpi"><div class="v" id="kpi-cost">$0.0000</div><div class="l">estimated input cost (USD)</div></div>
  <div class="panel kpi"><div class="v" id="kpi-requests">0</div><div class="l">requests</div></div>
  <div class="panel kpi"><div class="v" id="kpi-tokens">0</div><div class="l">input tokens</div></div>
  <div class="panel kpi"><div class="v" id="kpi-tokens-out">0</div><div class="l">output tokens</div></div>
  <div class="panel kpi"><div class="v" id="kpi-models">0</div><div class="l">distinct models</div></div>
  <div class="panel kpi"><div class="v" id="kpi-cache-hit">0%</div><div class="l">cache hit rate</div></div>
</div>

<div class="grid cols-2" style="margin-bottom: 16px;">
  <div class="panel">
    <h2>Per-model breakdown</h2>
    <table id="model-table">
      <thead><tr>
        <th>model</th><th class="num">requests</th><th class="num">input tok</th>
        <th class="num">output tok</th><th class="num">cost (USD)</th><th class="num">avg $/req</th>
        <th style="width: 140px;">share</th>
      </tr></thead>
      <tbody><tr><td colspan="7" class="empty">loading…</td></tr></tbody>
    </table>
  </div>
  <div class="panel">
    <h2>Feature breakdown</h2>
    <table id="feature-table">
      <thead><tr><th>feature</th><th class="num">requests</th><th class="num">share</th></tr></thead>
      <tbody><tr><td colspan="3" class="empty">loading…</td></tr></tbody>
    </table>
    <div class="small" style="margin-top: 12px;">thinking = requests with <code>thinking: {type:adaptive}</code>. tool = requests with <code>tools</code> array. text = the rest.</div>
  </div>
</div>

<div class="panel" style="margin-bottom: 16px;">
  <h2>Recent requests</h2>
  <table id="recent-table">
    <thead><tr>
      <th>time</th><th>model</th><th>feature</th>
      <th class="num">input</th><th class="num">output</th>
      <th class="num">cache read</th><th class="num">cost</th>
      <th>status</th>
    </tr></thead>
    <tbody><tr><td colspan="8" class="empty">loading…</td></tr></tbody>
  </table>
</div>

<div class="grid cols-3">
  <div class="panel">
    <h2>Cache performance</h2>
    <div id="cache-summary" class="small">loading…</div>
  </div>
  <div class="panel">
    <h2>Cost breakdown (per model)</h2>
    <table id="cost-table">
      <thead><tr><th>model</th><th class="num">$/M input</th><th class="num">$/M output</th></tr></thead>
      <tbody></tbody>
    </table>
  </div>
  <div class="panel">
    <h2>Provider routing health</h2>
    <div id="routing-health" class="small">loading…</div>
  </div>
</div>

<footer>MiniMax dashboard · data from <code>/stats</code> · auto-refresh every 10s</footer>
"""

_JS = """\
<script>
const REFRESH_MS = 10000;

async function loadStats() {
  try {
    const [statsRes, healthRes] = await Promise.all([
      fetch("/stats", { cache: "no-store" }),
      fetch("/health", { cache: "no-store" }),
    ]);
    if (!statsRes.ok) throw new Error("/stats " + statsRes.status);
    const d = await statsRes.json();
    if (healthRes.ok) {
      d.__health = await healthRes.json();
    }
    render(d);
    document.getElementById("last-update").textContent = "updated " + new Date().toLocaleTimeString();
    document.getElementById("live-pill").classList.add("live");
  } catch (e) {
    document.getElementById("live-pill").textContent = "offline";
    document.getElementById("live-pill").style.color = "var(--bad)";
  }
}

function getWindow(d) {
  const sel = document.getElementById("window-select").value;
  const ps = d.persistent_savings || {};
  return sel === "lifetime" ? (ps.lifetime || {}) : (ps.display_session || {});
}

function fmtUSD(n) {
  if (typeof n !== "number") return "$0.0000";
  if (n < 0.01) return "$" + n.toFixed(4);
  return "$" + n.toFixed(2);
}
function fmtInt(n) { return (n || 0).toLocaleString("en-US"); }
function fmtPct(n) { return (n * 100).toFixed(1) + "%"; }

function render(d) {
  const win = getWindow(d);
  const upstream = (d.__health && d.__health.checks && d.__health.checks.upstream && d.__health.checks.upstream.url) || "?";
  document.getElementById("upstream-pill").textContent = "upstream: " + upstream;

  // MiniMax-only logs (used for output tokens + cache hit detection,
  // since display_session doesn't track output_tokens separately).
  const logs = (d.request_logs || []).filter(r => (r.provider || "") === "minimax");

  // KPIs (window-level)
  const requests = win.requests || 0;
  const totalInput = win.total_input_tokens || 0;
  const totalOutput = logs.reduce((s, r) => s + (r.output_tokens || 0), 0);
  const totalCost = win.total_input_cost_usd || 0;
  document.getElementById("kpi-cost").textContent = fmtUSD(totalCost);
  document.getElementById("kpi-requests").textContent = fmtInt(requests);
  document.getElementById("kpi-tokens").textContent = fmtInt(totalInput);
  document.getElementById("kpi-tokens-out").textContent = fmtInt(totalOutput);

  // MiniMax-specific data: log buffer + per_model + prefix_cache
  const perModel = (d.cost && d.cost.per_model) || {};
  const cacheByProv = (d.prefix_cache && d.prefix_cache.by_provider && d.prefix_cache.by_provider.minimax) || {};

  // Build per-model table — combine per_model stats (cumulative) with log entries (recent)
  const models = new Set();
  Object.keys(perModel).forEach(m => models.add(m));
  logs.forEach(r => r.model && models.add(r.model));
  const modelRows = [...models].map(m => {
    const p = perModel[m] || {};
    const logEntries = logs.filter(r => r.model === m);
    // Prefer log data (recent + has provider field) over cumulative per_model
    const modelReqs = logEntries.length > 0 ? logEntries.length : (p.requests || 0);
    const input = p.tokens_sent || logEntries.reduce((s, r) => s + (r.input_tokens_original || r.input_tokens || 0), 0);
    const output = p.tokens_sent ? 0 : logEntries.reduce((s, r) => s + (r.output_tokens || 0), 0);
    const cost = input * (PRICING[m]?.input_per_token || 0);
    return {
      model: m,
      requests: modelReqs,
      input: input,
      output: output,
      cost: cost,
      avgPerReq: modelReqs > 0 ? cost / modelReqs : 0
    };
  }).filter(r => r.requests > 0).sort((a, b) => b.requests - a.requests);

  const totalReqForShare = modelRows.reduce((s, r) => s + r.requests, 0) || 1;
  document.getElementById("kpi-models").textContent = modelRows.length;
  // Cache hit rate: % of recent MiniMax log entries with cache_hit=true
  const cacheHitsFromLogs = logs.filter(r => r.cache_hit).length;
  document.getElementById("kpi-cache-hit").textContent = logs.length > 0 ? fmtPct(cacheHitsFromLogs / logs.length) : "0%";

  const tbody = document.querySelector("#model-table tbody");
  if (modelRows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="empty">no MiniMax traffic in this window</td></tr>';
  } else {
    tbody.innerHTML = modelRows.map(r => {
      const share = r.requests / totalReqForShare;
      return `<tr>
        <td><code>${r.model}</code></td>
        <td class="num">${fmtInt(r.requests)}</td>
        <td class="num">${fmtInt(r.input)}</td>
        <td class="num">${fmtInt(r.output)}</td>
        <td class="num">${fmtUSD(r.cost)}</td>
        <td class="num">${fmtUSD(r.avgPerReq)}</td>
        <td><div class="bar"><i style="width:${(share*100).toFixed(1)}%"></i></div><div class="small" style="margin-top:2px">${(share*100).toFixed(1)}%</div></td>
      </tr>`;
    }).join("");
  }

  // Feature breakdown: detect from transforms_applied / cache_hit fields
  renderFeatureBreakdown(logs);

  // Recent requests table
  const recentTbody = document.querySelector("#recent-table tbody");
  const recent = logs.slice(0, 20);
  if (recent.length === 0) {
    recentTbody.innerHTML = '<tr><td colspan="8" class="empty">no recent MiniMax requests</td></tr>';
  } else {
    recentTbody.innerHTML = recent.map(r => {
      const ts = r.timestamp ? new Date(r.timestamp).toLocaleTimeString() : "—";
      const feature = detectFeature(r);
      const input = fmtInt(r.input_tokens_original || r.input_tokens || 0);
      const output = fmtInt(r.output_tokens || 0);
      const cacheRead = fmtInt(r.cache_read_input_tokens || 0);
      const modelCost = (r.input_tokens_original || 0) * (PRICING[r.model]?.input_per_token || 0);
      const cost = fmtUSD(modelCost);
      const status = r.failed ? "FAIL" : (r.cache_hit ? "cache" : "OK");
      const statusColor = status === "FAIL" ? "var(--bad)" : (status === "cache" ? "var(--accent)" : "var(--good)");
      return `<tr>
        <td class="small">${ts}</td>
        <td><code>${r.model || "?"}</code></td>
        <td>${feature}</td>
        <td class="num">${input}</td>
        <td class="num">${output}</td>
        <td class="num">${cacheRead}</td>
        <td class="num">${cost}</td>
        <td style="color:${statusColor}">${status}</td>
      </tr>`;
    }).join("");
  }

  // Cache performance
  const cacheDiv = document.getElementById("cache-summary");
  const netSav = cacheByProv.net_savings_usd || 0;
  const writePrem = cacheByProv.write_premium_usd || 0;
  const cacheReads = cacheByProv.cache_read_tokens || 0;
  cacheDiv.innerHTML = `
    <div>cache_read_tokens: <strong>${fmtInt(cacheReads)}</strong></div>
    <div>net_savings: <strong>${fmtUSD(netSav)}</strong></div>
    <div>write_premium: <strong>${fmtUSD(writePrem)}</strong></div>
    <div class="small" style="margin-top: 8px;">cache_savings_usd ${fmtUSD(cacheByProv.savings_usd || 0)}</div>
  `;

  // Cost breakdown
  const costTbody = document.querySelector("#cost-table tbody");
  costTbody.innerHTML = Object.entries(PRICING).map(([m, p]) => {
    const inPerM = (p.input_per_token || 0) * 1e6;
    const outPerM = (p.output_per_token || 0) * 1e6;
    return `<tr><td><code>${m}</code></td><td class="num">$${inPerM.toFixed(2)}</td><td class="num">$${outPerM.toFixed(2)}</td></tr>`;
  }).join("");

  // Routing health
  const rhDiv = document.getElementById("routing-health");
  const upstreamHost = (() => { try { return new URL(upstream).hostname; } catch { return "?"; } })();
  rhDiv.innerHTML = `
    <div>upstream host: <strong>${upstreamHost}</strong></div>
    <div>configured URL: <code style="font-size: 11px;">${upstream}</code></div>
    <div class="small" style="margin-top: 8px;">auth: <code>Token: &lt;jwt&gt;</code> (managed provider)</div>
  `;
}

// Pricing table — must mirror MiniMaxProvider.MODEL_INPUT_COST / OUTPUT_COST
// (in USD per 1M tokens). Updated by the server side; for the dashboard
// we hard-code the same values so the page works offline.
const PRICING = {
  "MiniMax-M3":             { input_per_token: 1e-6,  output_per_token: 5e-6 },
  "MiniMax-M2.7":           { input_per_token: 0.8e-6, output_per_token: 4e-6 },
  "MiniMax-M2.7-highspeed": { input_per_token: 0.5e-6, output_per_token: 2.5e-6 },
  "MiniMax-M2.5":           { input_per_token: 0.5e-6, output_per_token: 2.5e-6 },
  "MiniMax-M2.5-highspeed": { input_per_token: 0.3e-6, output_per_token: 1.5e-6 },
  "MiniMax-M2.1":           { input_per_token: 0.3e-6, output_per_token: 1.5e-6 },
  "MiniMax-M2.1-highspeed": { input_per_token: 0.2e-6, output_per_token: 1e-6 },
  "MiniMax-M2":             { input_per_token: 0.2e-6, output_per_token: 1e-6 },
};

function detectFeature(logEntry) {
  // Best-effort feature detection from log fields:
  //   - `cache_hit: true` → "cache hit" (the request was served from
  //     headroom's response cache, not the upstream API)
  //   - otherwise → "text"
  //
  // Note: thinking/tool_use flags aren't reliably surfaced in
  // `/stats > request_logs` today (only in debug payloads). When the
  // server-side log includes them, we add detection here.
  if (logEntry.cache_hit) return '<span class="tag" style="color:var(--accent)">cache hit</span>';
  // Heuristic: presence of "thinking_*" in transforms indicates thinking
  const t = logEntry.transforms_applied || [];
  if (t.some(s => s.startsWith("thinking:") || s === "thinking")) {
    return '<span class="tag thinking">thinking</span>';
  }
  // Heuristic for tool_use: look at the tool_count tag set elsewhere.
  if (logEntry.tags && logEntry.tags.tool_count && logEntry.tags.tool_count !== "0") {
    return '<span class="tag tool">tool_use</span>';
  }
  return "text";
}

function renderFeatureBreakdown(logs) {
  let text = 0, cache = 0;
  logs.forEach(r => {
    if (r.cache_hit) cache++;
    else text++;
  });
  const total = logs.length || 1;
  const tbody = document.querySelector("#feature-table tbody");
  if (logs.length === 0) {
    tbody.innerHTML = '<tr><td colspan="3" class="empty">no MiniMax traffic</td></tr>';
  } else {
    tbody.innerHTML = `
      <tr><td>text</td><td class="num">${text}</td><td class="num">${(text/total*100).toFixed(1)}%</td></tr>
      <tr><td><span class="tag" style="color:var(--accent)">cache hit</span></td><td class="num">${cache}</td><td class="num">${(cache/total*100).toFixed(1)}%</td></tr>
      <tr><td colspan="3" class="small" style="padding-top:8px">thinking/tool_use detection requires per-request log enrichment (proxy.log file). Auto-refresh: 10s.</td></tr>
    `;
  }
}

loadStats();
setInterval(loadStats, REFRESH_MS);
</script>
</body>
</html>
"""


_MINIMAX_DASHBOARD_HTML = _HTML_HEAD + _BODY + _JS


__all__ = ["get_minimax_dashboard_html"]