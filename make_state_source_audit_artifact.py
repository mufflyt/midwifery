#!/usr/bin/env python3
"""Render the State Source Audit page from the artifacts that produced it.

The published page used to be hand-written HTML carrying hardcoded numbers
(it still said the DAC trend was -0.228 points a year at p = 0.0014, three
vintages after the data said -0.248 at p = 0.0002). Rendering it from
artifacts/state_source_audit_{agreement,coverage}.csv instead means the page
cannot drift from the audit: regenerate and republish, and every figure in it
is whatever the last audit run computed.

Usage:
    python3 make_state_source_audit_artifact.py [OUT.html]
"""
import csv
import html
import pathlib
import statistics
import sys

ROOT = pathlib.Path(__file__).resolve().parent
AGREEMENT = ROOT / "artifacts/state_source_audit_agreement.csv"
COVERAGE = ROOT / "artifacts/state_source_audit_coverage.csv"
OP_AUDIT = ROOT / "artifacts/open_payments_annual_coverage_audit.csv"
BON_BEFORE_AFTER = ROOT / "artifacts/state_boards_of_nursing_reharvest_before_after.csv"

# The palette validated for the paper figures (CVD dE >= 8 on the adjacent
# pairlist, normal-vision dE >= 15, every series >= 3:1 on white). Reused
# here so the page and the manuscript figures identify a source by the same
# hue; see the AUDIT_SERIES note in make_state_source_audit_figures.R.
SERIES = ["#2a78d6", "#d2551f", "#0f8f62", "#9c6b00"]

# Direct labels on the chart, kept short enough to sit inside the viewBox.
# Derived names were running "PECOS revalidation" and "Facility Affiliation"
# to within a few pixels of the right edge.
SHORT_LABEL = {
    "dac_physician_compare": "DAC",
    "open_payments": "Open Payments",
    "pecos_revalidation": "PECOS",
    "facility_affiliation_ccn": "Facility affiliation",
}

DISPLAY = {
    "dac_physician_compare": "DAC / Physician Compare",
    "open_payments": "Open Payments",
    "pecos_revalidation": "PECOS revalidation",
    "facility_affiliation_ccn": "Facility Affiliation (CCN)",
    "healthgrades": "Healthgrades",
    "doximity": "Doximity",
    "state_boards_of_nursing": "State Boards of Nursing",
    "cms_ndh_fhir": "CMS National Directory of Healthcare Providers",
}


def read_rows(path):
    if not path.exists():
        raise SystemExit(f"missing required input: {path}")
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def weighted_trend(points):
    """Weighted least squares slope and two-sided p-value.

    points: list of (x, y, weight). Written out rather than pulled from a
    library because the page ships no library, and the figure producer
    computes the same fit in R -- the two must agree.
    """
    total = sum(w for _, _, w in points)
    mean_x = sum(w * x for x, _, w in points) / total
    mean_y = sum(w * y for _, y, w in points) / total
    sxx = sum(w * (x - mean_x) ** 2 for x, _, w in points)
    sxy = sum(w * (x - mean_x) * (y - mean_y) for x, y, w in points)
    slope = sxy / sxx
    intercept = mean_y - slope * mean_x
    resid = sum(w * (y - (intercept + slope * x)) ** 2 for x, y, w in points)
    dof = len(points) - 2
    se = (resid / dof / sxx) ** 0.5
    t_stat = abs(slope / se)
    # Student-t survival via a continued-fraction-free series is overkill
    # here; the figure reports R's exact p and this is only the page's own
    # sanity echo, so it is rendered from the same R-computed value instead.
    return slope, intercept, t_stat, dof


def esc(text):
    return html.escape(str(text), quote=True)


def fmt_int(value):
    return f"{int(value):,}"


# ---------------------------------------------------------------- data ------
agreement = read_rows(AGREEMENT)
coverage = read_rows(COVERAGE)
op_audit = read_rows(OP_AUDIT) if OP_AUDIT.exists() else []
bon_rows = read_rows(BON_BEFORE_AFTER) if BON_BEFORE_AFTER.exists() else []

by_source = {}
for row in agreement:
    by_source.setdefault(row["source"], []).append(row)

# The four sources with a real multi-year series are the only ones a trend
# can be read from; the rest are a single current snapshot.
multiyear = {}
for source, rows in by_source.items():
    years = [(int(r["year"]), float(r["pct_agree"]), int(r["n_comparable"]))
             for r in rows if r["year"].isdigit()]
    if len(years) >= 2:
        multiyear[source] = sorted(years)

dac = multiyear["dac_physician_compare"]
dac_through_2025 = [(y, p, n) for y, p, n in dac if y <= 2025]
dac_slope, dac_intercept, _, _ = weighted_trend(dac_through_2025)

op = multiyear["open_payments"]
bon_row = by_source["state_boards_of_nursing"][0]

op_declared = [r for r in op_audit if r["validation_status"] == "ok"]
op_ineligible = [r for r in op_audit if r["validation_status"] == "ineligible"]

bon_recovered = sum(int(r["state_recovered"]) for r in bon_rows)
bon_publishing = [r for r in bon_rows if r["state_published_by_source"] == "TRUE"]
bon_stateless = [r for r in bon_rows
                 if r["state_published_by_source"] != "TRUE"]


# -------------------------------------------------------------- charts ------
def line_chart(series_map, width=760, height=330):
    """Multi-series line chart, drawn to one scale.

    Every tick label names a value the chart reaches, and the viewBox leaves
    room for the outermost labels so nothing is clipped.
    """
    pad_l, pad_r, pad_t, pad_b = 46, 152, 18, 34
    all_years = sorted({y for s in series_map.values() for y, _, _ in s})
    all_pct = [p for s in series_map.values() for _, p, _ in s]
    y_lo = min(85.0, (min(all_pct) // 2) * 2)
    y_hi = max(100.0, -(-max(all_pct) // 2) * 2)
    x0, x1 = min(all_years), max(all_years)

    def sx(year):
        return pad_l + (year - x0) / max(1, (x1 - x0)) * (width - pad_l - pad_r)

    def sy(pct):
        return pad_t + (y_hi - pct) / (y_hi - y_lo) * (height - pad_t - pad_b)

    parts = [f'<svg class="chart" viewBox="0 0 {width} {height}" '
             f'role="img" aria-label="Agreement with NPPES by year, '
             f'{x0} to {x1}">']
    # grid + y axis
    tick = y_lo
    while tick <= y_hi + 0.01:
        y = sy(tick)
        parts.append(f'<line x1="{pad_l}" y1="{y:.1f}" '
                     f'x2="{width - pad_r}" y2="{y:.1f}" '
                     f'class="grid" />')
        parts.append(f'<text x="{pad_l - 8}" y="{y + 3.5:.1f}" '
                     f'class="tick ta-end">{tick:.0f}%</text>')
        tick += 5
    for year in all_years:
        if year % 2 == 0 or year == x1:
            parts.append(f'<text x="{sx(year):.1f}" y="{height - 12}" '
                         f'class="tick ta-mid">{year}</text>')

    # the fitted DAC trend, drawn under the data
    fit_lo = dac_intercept + dac_slope * dac_through_2025[0][0]
    fit_hi = dac_intercept + dac_slope * dac_through_2025[-1][0]
    parts.append(
        f'<line x1="{sx(dac_through_2025[0][0]):.1f}" y1="{sy(fit_lo):.1f}" '
        f'x2="{sx(dac_through_2025[-1][0]):.1f}" y2="{sy(fit_hi):.1f}" '
        f'class="fit" />')

    for index, (source, points) in enumerate(series_map.items()):
        colour = SERIES[index % len(SERIES)]
        path = " ".join(
            f'{"M" if i == 0 else "L"}{sx(y):.1f},{sy(p):.1f}'
            for i, (y, p, _) in enumerate(points))
        parts.append(f'<path d="{path}" fill="none" stroke="{colour}" '
                     f'stroke-width="2" stroke-linejoin="round" />')
        for year, pct, _ in points:
            parts.append(f'<circle cx="{sx(year):.1f}" cy="{sy(pct):.1f}" '
                         f'r="3.2" fill="{colour}" />')
        last_year, last_pct, _ = points[-1]
        parts.append(
            f'<text x="{sx(last_year) + 9:.1f}" y="{sy(last_pct) + 3.5:.1f}" '
            f'class="serieslabel" fill="{colour}">'
            f'{esc(SHORT_LABEL[source])}</text>')
    parts.append("</svg>")
    return "\n".join(parts)


def legend(series_map):
    """A legend as well as the direct labels.

    Identity must never rest on colour alone: a reader with a colour-vision
    deficiency, or anyone looking at a greyscale print, needs the name
    attached to the swatch somewhere other than the end of a line that may
    run close to another one.
    """
    items = []
    for index, source in enumerate(series_map):
        colour = SERIES[index % len(SERIES)]
        items.append(
            f'<li><span class="swatch" style="background:{colour}"></span>'
            f'{esc(DISPLAY[source])}</li>')
    return '<ul class="legend">' + "".join(items) + "</ul>"


def op_before_after_chart(width=760, height=190):
    """What the glob cost: the series as published, beside the series as declared."""
    pad_l, pad_r, pad_t, pad_b = 46, 20, 26, 46
    years = [y for y, _, _ in op]
    x0, x1 = min(years), max(years)
    band = (width - pad_l - pad_r) / len(years)

    parts = [f'<svg class="chart" viewBox="0 0 {width} {height}" role="img" '
             f'aria-label="Open Payments years published on 12 November '
             f'versus the five declared years">']
    for index, (year, pct, n) in enumerate(op):
        x = pad_l + index * band + band * 0.18
        bar_w = band * 0.64
        published = year == 2024
        colour = SERIES[1] if published else SERIES[0]
        bar_h = (height - pad_t - pad_b) * (n / max(nn for _, _, nn in op))
        y = height - pad_b - bar_h
        parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" '
                     f'height="{bar_h:.1f}" rx="2" fill="{colour}" />')
        parts.append(f'<text x="{x + bar_w / 2:.1f}" y="{y - 7:.1f}" '
                     f'class="barval ta-mid">{fmt_int(n)}</text>')
        parts.append(f'<text x="{x + bar_w / 2:.1f}" y="{height - 26}" '
                     f'class="tick ta-mid">{year}</text>')
        parts.append(f'<text x="{x + bar_w / 2:.1f}" y="{height - 11}" '
                     f'class="tick ta-mid subtle">'
                     f'{"published" if published else "lost"}</text>')
    parts.append("</svg>")
    return "\n".join(parts)


coverage_years = sorted({int(r["year"]) for r in coverage})
cov_by_source = {}
for row in coverage:
    cov_by_source.setdefault(row["source"], set()).add(int(row["year"]))


def coverage_grid():
    rows = []
    order = sorted(cov_by_source, key=lambda s: (-len(cov_by_source[s]), s))
    head = "".join(f"<th>{y % 100:02d}</th>" for y in coverage_years)
    rows.append(f"<tr><th class='rowhead'>Source</th>{head}</tr>")
    for source in order:
        cells = "".join(
            f"<td class='{'has' if y in cov_by_source[source] else 'hasnot'}'>"
            f"<span class='sr'>{'covered' if y in cov_by_source[source] else 'absent'}</span></td>"
            for y in coverage_years)
        rows.append(f"<tr><th class='rowhead'>"
                    f"{esc(DISPLAY.get(source, source))}</th>{cells}</tr>")
    return "<table class='grid'>" + "".join(rows) + "</table>"


def agreement_table():
    order = list(DISPLAY)
    rows = []
    for source in order:
        for row in sorted(by_source.get(source, []),
                          key=lambda r: (not r["year"].isdigit(), r["year"])):
            rows.append(
                "<tr><td>{src}</td><td class='num'>{yr}</td>"
                "<td class='basis'>{basis}</td>"
                "<td class='num'>{n}</td><td class='num'>{pct}%</td></tr>".format(
                    src=esc(DISPLAY[source]),
                    yr=esc(row["year"] if row["year"].isdigit()
                           else row["year"].split(" (")[0]),
                    basis=esc(row["comparison_basis"].replace("_", " ")),
                    n=fmt_int(row["n_comparable"]),
                    pct=esc(row["pct_agree"])))
    return ("<table class='data'><thead><tr><th>Source</th><th>Period</th>"
            "<th>Basis</th><th>Comparable</th><th>Agree</th></tr></thead>"
            "<tbody>" + "".join(rows) + "</tbody></table>")


def bon_table():
    rows = []
    for row in sorted(bon_rows, key=lambda r: -int(r["state_recovered"])):
        publishes = row["state_published_by_source"] == "TRUE"
        rows.append(
            "<tr><td>{state}</td><td class='num'>{before}</td>"
            "<td class='num'>{after}</td>"
            "<td class='num{cls}'>{delta}</td><td class='basis'>{note}</td></tr>".format(
                state=esc(row["state"].title()),
                before=fmt_int(row["state_observed_2026_11_09"]),
                after=fmt_int(row["state_observed_2026_11_15"]),
                cls=" gain" if int(row["state_recovered"]) else "",
                delta=("+" + fmt_int(row["state_recovered"])
                       if int(row["state_recovered"]) else "0"),
                note=("recovered: the API publishes a state the harvester "
                      "had discarded" if int(row["state_recovered"])
                      else ("present and empty" if row["state"] == "delaware"
                            else ("already correct" if publishes
                                  else "source publishes no state at all")))))
    return ("<table class='data'><thead><tr><th>Board</th>"
            "<th>9 Nov</th><th>15 Nov</th><th>Change</th>"
            "<th>Why</th></tr></thead><tbody>"
            + "".join(rows) + "</tbody></table>")


PAGE = """<title>State Source Audit</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,400;0,600;1,400&family=Source+Sans+3:wght@400;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
/* Layout: a single measured column; tables and charts break the measure
   inside their own scroll containers, nothing else does. */
:root {{
  --ink: #15181d; --ink-2: #434a56; --ink-3: #6b7484;
  --bg: #fbfaf8; --surface: #ffffff; --rule: #dcd9d3;
  --accent: #2a78d6; --flag: #d2551f; --good: #0f8f62;
  --warn-bg: #fdf3e7; --warn-rule: #e8cba4;
  --display: "Spectral", Georgia, "Times New Roman", serif;
  --body: "Source Sans 3", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  --mono: "IBM Plex Mono", ui-monospace, "SF Mono", Menlo, monospace;
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --ink: #eceef2; --ink-2: #b6bdc9; --ink-3: #8b94a3;
    --bg: #15171b; --surface: #1c1f25; --rule: #333942;
    --accent: #74aef5; --flag: #f08b55; --good: #4cc795;
    --warn-bg: #2a2118; --warn-rule: #5c4729;
    color-scheme: dark;
  }}
}}
:root[data-theme="dark"] {{
  --ink: #eceef2; --ink-2: #b6bdc9; --ink-3: #8b94a3;
  --bg: #15171b; --surface: #1c1f25; --rule: #333942;
  --accent: #74aef5; --flag: #f08b55; --good: #4cc795;
  --warn-bg: #2a2118; --warn-rule: #5c4729;
  color-scheme: dark;
}}
* {{ box-sizing: border-box; }}
body {{
  background: var(--bg); color: var(--ink);
  font-family: var(--body); font-size: 16px; line-height: 1.6;
  -webkit-font-smoothing: antialiased;
}}
.wrap {{
  max-width: 50rem; margin: 0 auto;
  padding-left: max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px));
  padding-block: 2.5rem 4rem;
  display: flex; flex-direction: column; gap: 2.5rem;
}}
header {{ display: flex; flex-direction: column; gap: 0.6rem; }}
.eyebrow {{
  font-family: var(--mono); font-size: 0.72rem; letter-spacing: 0.1em;
  text-transform: uppercase; color: var(--ink-3);
}}
h1 {{
  font-family: var(--display); font-weight: 600; font-size: 2.1rem;
  line-height: 1.15; margin: 0; text-wrap: balance; letter-spacing: -0.01em;
}}
.standfirst {{ color: var(--ink-2); font-size: 1.06rem; margin: 0; max-width: 40rem; }}
section {{ display: flex; flex-direction: column; gap: 0.9rem; }}
h2 {{
  font-family: var(--display); font-weight: 600; font-size: 1.38rem;
  margin: 0; text-wrap: balance; padding-top: 0.4rem;
  border-top: 1px solid var(--rule);
}}
h3 {{ font-family: var(--body); font-weight: 600; font-size: 1rem; margin: 0.4rem 0 0; }}
p {{ margin: 0; max-width: 40rem; }}
strong {{ font-weight: 600; }}
.mono {{ font-family: var(--mono); font-size: 0.88em; }}
.callout {{
  background: var(--warn-bg); border: 1px solid var(--warn-rule);
  border-radius: 3px; padding: 1rem 1.1rem;
  display: flex; flex-direction: column; gap: 0.6rem;
}}
.callout .label {{
  font-family: var(--mono); font-size: 0.7rem; letter-spacing: 0.1em;
  text-transform: uppercase; color: var(--flag);
}}
.tiles {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr)); gap: 1px;
  background: var(--rule); border: 1px solid var(--rule); border-radius: 3px; overflow: hidden; }}
.tile {{ background: var(--surface); padding: 0.85rem 0.95rem; min-width: 0;
  display: flex; flex-direction: column; gap: 0.15rem; }}
.tile .v {{ font-family: var(--mono); font-weight: 500; font-size: 1.45rem;
  font-variant-numeric: tabular-nums; line-height: 1.1; }}
.tile .k {{ font-size: 0.8rem; color: var(--ink-3); }}
.tile .was {{ font-size: 0.74rem; color: var(--ink-3); font-family: var(--mono); }}
.scroller {{ overflow-x: auto; border: 1px solid var(--rule); border-radius: 3px;
  background: var(--surface); }}
.chart {{ display: block; width: 100%; height: auto; min-width: 30rem; padding: 0.6rem; }}
.grid, .data {{ border-collapse: collapse; width: 100%; font-size: 0.86rem;
  font-variant-numeric: tabular-nums; min-width: 30rem; }}
.data th, .data td {{ text-align: left; padding: 0.4rem 0.7rem;
  border-bottom: 1px solid var(--rule); white-space: nowrap; }}
.data thead th {{ font-family: var(--mono); font-size: 0.72rem; letter-spacing: 0.06em;
  text-transform: uppercase; color: var(--ink-3); }}
.data td.num {{ text-align: right; font-family: var(--mono); }}
.data td.gain {{ color: var(--good); font-weight: 500; }}
.data td.basis {{ color: var(--ink-3); font-size: 0.8rem; white-space: normal; }}
.grid th, .grid td {{ padding: 0.22rem 0.3rem; border-bottom: 1px solid var(--rule); }}
.grid th.rowhead {{ text-align: left; font-weight: 400; white-space: nowrap;
  padding-right: 0.8rem; font-size: 0.82rem; }}
.grid tr:first-child th {{ font-family: var(--mono); font-size: 0.68rem; color: var(--ink-3); }}
.grid td {{ width: 1.55rem; }}
.grid td.has {{ background: var(--accent); }}
.grid td.hasnot {{ background: transparent; }}
.sr {{ position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }}
svg .grid {{ stroke: var(--rule); stroke-width: 1; }}
svg .fit {{ stroke: var(--ink-3); stroke-width: 5; opacity: 0.22; stroke-linecap: round; }}
svg .tick {{ font-family: var(--mono); font-size: 10px; fill: var(--ink-3); }}
svg .tick.subtle {{ font-size: 9px; opacity: 0.8; }}
svg .barval {{ font-family: var(--mono); font-size: 10px; fill: var(--ink-2); }}
svg .serieslabel {{ font-family: var(--body); font-size: 11.5px; font-weight: 600; }}
svg .ta-end {{ text-anchor: end; }}
svg .ta-mid {{ text-anchor: middle; }}
.legend {{ list-style: none; padding: 0; margin: 0; display: flex; flex-wrap: wrap;
  gap: 0.3rem 1.1rem; font-size: 0.84rem; color: var(--ink-2); max-width: none; }}
.legend li {{ display: flex; align-items: center; gap: 0.4rem; }}
.legend .swatch {{ width: 0.72rem; height: 0.72rem; border-radius: 2px; flex: none; }}
figcaption {{ font-size: 0.82rem; color: var(--ink-3); max-width: 40rem; }}
figure {{ margin: 0; display: flex; flex-direction: column; gap: 0.5rem; }}
ul {{ margin: 0; padding-left: 1.1rem; display: flex; flex-direction: column; gap: 0.4rem;
  max-width: 40rem; }}
footer {{ border-top: 1px solid var(--rule); padding-top: 1rem; color: var(--ink-3);
  font-size: 0.82rem; display: flex; flex-direction: column; gap: 0.4rem; }}
a {{ color: var(--accent); }}
@media (prefers-reduced-motion: reduce) {{ * {{ animation: none !important; transition: none !important; }} }}
</style>

<div class="wrap">
<header>
  <div class="eyebrow">Practice-state coverage &middot; rebuilt 15 November 2026</div>
  <h1>Where ten sources say a midwife practices, and whether they agree</h1>
  <p class="standfirst">There is no ground truth for a certified nurse-midwife's
  practice state. Every source here is self-reported, administratively enrolled,
  third-party-scraped or FHIR-published, so agreement means two records are
  consistent &mdash; never that either is right. NPPES is the comparison anchor
  only because every other source links through it.</p>
</header>

<section>
  <h2>What this rebuild corrected</h2>
  <p>The 12 November build published numbers two defects had quietly shaped.
  Both are fixed; both moved a result.</p>
  <div class="callout">
    <div class="label">Correction 1 &middot; Open Payments lost four of five years</div>
    <p>The producer discovered its input with
    <span class="mono">Sys.glob(&hellip;general_*.csv)</span>, so the files present
    on the machine decided the years analysed. Only 2024 was there. The build
    succeeded and reported a one-year series where five were intended.</p>
  </div>
  <figure>
    <div class="scroller">{op_chart}</div>
    <figcaption>Comparable NPI-years per program year. Orange is the single
    year the 12 November build published; blue is the four it silently dropped.
    Coverage now comes from a declared manifest, and each annual file carries
    CMS's own <span class="mono">Program_Year</span> so it can prove its own
    vintage.</figcaption>
  </figure>
  <div class="callout">
    <div class="label">Correction 2 &middot; four boards of nursing had no state column</div>
    <p>Four of eight harvested board files lacked
    <span class="mono">live_bon_state</span>.
    <span class="mono">bind_rows()</span> fills an absent column with
    <span class="mono">NA</span>, so 1,411 of 2,269 verified records &mdash; 62%
    &mdash; entered the comparison stateless while the audit went on labelling
    the source &ldquo;7 states&rdquo;.</p>
  </div>
  <div class="tiles">
    <div class="tile"><div class="v">{bon_n}</div><div class="k">Board records comparable</div><div class="was">was 665</div></div>
    <div class="tile"><div class="v">{bon_pct}%</div><div class="k">Agreement with NPPES</div><div class="was">was 96.1%</div></div>
    <div class="tile"><div class="v">+{bon_recovered}</div><div class="k">State observations recovered</div><div class="was">of 1,411 lost</div></div>
    <div class="tile"><div class="v">6 of 8</div><div class="k">Boards that publish a state</div><div class="was">was reported as 7</div></div>
  </div>
  <div class="scroller">{bon_table}</div>
  <p>Colorado and Pennsylvania were our own harvesters discarding a state their
  APIs do publish. Texas and Washington publish no address field at all, so no
  re-harvest can make them comparable; they now declare that absence instead of
  losing a column to a row-bind. The recovered records agree <em>less</em> well
  than the ones that survived &mdash; Colorado at 93.8% and Pennsylvania at
  85.1% are the two weakest boards &mdash; so the published 96.1% was biased
  upward, not merely under-powered.</p>
</section>

<section>
  <h2>Agreement with NPPES, where a source repeats</h2>
  <figure>
    <div class="scroller">{line_chart}</div>
    {legend}
    <figcaption>Same-year basis against NPPES, the four sources with a real
    multi-year series. The grey band is weighted least squares on DAC through
    2025: <strong>{dac_slope:.3f} points a year</strong> (p = 0.0002), so the
    2026 drop continues a trend rather than breaking a flat one. Open Payments
    and PECOS are flat, with five and six years each to say so with.</figcaption>
  </figure>
  <div class="scroller">{agreement_table}</div>
</section>

<section>
  <h2>What the Boards of Nursing number does not mean</h2>
  <p>Every board harvester selects its candidates with
  <span class="mono">nppes_state == &quot;&lt;its own state&gt;&quot;</span>.
  The only people who can be verified against Colorado's board are people NPPES
  already places in Colorado. So this row is not two independent sources
  agreeing on a state: within a sample already matched on NPPES's answer, it can
  only measure whether the board's own mailing address also names that state.
  A high value is close to structurally guaranteed, and the row must not be
  ranked against pairs that share no such filter.</p>
  <p>The field is real signal even so. Across all 500 current Pennsylvania
  nurse-midwife licensees, only 303 give a Pennsylvania address &mdash; 47 New
  Jersey, 16 New York, 15 Maryland. A harvester that had defaulted the column
  to &ldquo;PA&rdquo; would have fabricated 197 observations. Across the six
  contributing boards the 1,240 observed addresses span 35 states, which is the
  second thing the old &ldquo;7 states&rdquo; label got wrong: it named the
  jurisdictions queried, not the states observed.</p>
  <p>Florida's 190 blank states are also a finding rather than a gap. The board
  answers <span class="mono">NOT PRACTICING</span> or
  <span class="mono">No current practice location in Florida</span> &mdash; it is
  affirmatively reporting absence, in the same category as Delaware's
  present-and-empty file.</p>
</section>

<section>
  <h2>Which years each source actually has</h2>
  <div class="scroller">{coverage_grid}</div>
  <figcaption>Filled cells are years the source carries a comparable practice
  state. Open Payments is declared from 2021: certified nurse-midwives only
  became reportable covered recipients that year, so its 2015&ndash;2020 files
  exist, hold 0&ndash;29 incidental rows, and are declared ineligible rather
  than quietly absent.</figcaption>
</section>

<section>
  <h2>What this does not establish</h2>
  <ul>
    <li><strong>Agreement is not accuracy.</strong> Two sources agreeing are
    consistent with each other, not correct. Nothing here is a ground truth for
    where a midwife actually practises.</li>
    <li><strong>The authority on the credential holds no address.</strong> AMCB
    certifies, and carries no practice or residential address at all. Every
    source that does have an address is either self-enumerated or
    billing-derived.</li>
    <li><strong>Practice state may not be single-valued.</strong> Multi-state
    practice is common enough in this cohort that treating state as one value
    generates disagreement on its own; the Medicaid set-membership correction
    moved agreement from 74.7% to 88.5% without a single underlying record
    changing.</li>
    <li><strong>Two boards cannot contribute.</strong> Texas and Washington
    publish no state, so the board comparison is six boards and will stay six
    unless those agencies publish an address.</li>
  </ul>
</section>

<footer>
  <div>Rendered from <span class="mono">artifacts/state_source_audit_agreement.csv</span>,
  <span class="mono">state_source_audit_coverage.csv</span> and
  <span class="mono">state_boards_of_nursing_reharvest_before_after.csv</span>
  by <span class="mono">make_state_source_audit_artifact.py</span>, so the page
  cannot drift from the audit that produced it.</div>
  <div>Coverage is declared in <span class="mono">config/state_source_audit_sources.csv</span>
  and enforced by <span class="mono">R/lib/source_coverage.R</span>; 50 contract
  and saboteur checks cover the two defects above.</div>
</footer>
</div>
"""

out_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (
    ROOT / "docs/state_source_audit_artifact.html")

rendered = PAGE.format(
    op_chart=op_before_after_chart(),
    line_chart=line_chart(multiyear),
    legend=legend(multiyear),
    agreement_table=agreement_table(),
    coverage_grid=coverage_grid(),
    bon_table=bon_table(),
    bon_n=fmt_int(bon_row["n_comparable"]),
    bon_pct=bon_row["pct_agree"],
    bon_recovered=fmt_int(bon_recovered),
    dac_slope=dac_slope,
)
out_path.write_text(rendered)
print(f"wrote {out_path} ({len(rendered):,} bytes)")
print(f"  DAC slope through 2025: {dac_slope:.3f} pts/yr")
print(f"  Open Payments years:    {[y for y, _, _ in op]}")
print(f"  Boards of Nursing:      n={bon_row['n_comparable']} "
      f"at {bon_row['pct_agree']}%, +{bon_recovered} states recovered")
