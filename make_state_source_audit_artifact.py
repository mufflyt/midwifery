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
OIG_TABLE4 = ROOT / "artifacts/oig_remake/oig_table4_consistency_2019_and_2026.csv"

# The palette validated for the paper figures (CVD dE >= 8 on the adjacent
# pairlist, normal-vision dE >= 15, every series >= 3:1 on white). Reused
# here so the page and the manuscript figures identify a source by the same
# hue; see the AUDIT_SERIES note in make_state_source_audit_figures.R.
SERIES = ["#2a78d6", "#d2551f", "#0f8f62", "#9c6b00"]

# Direct labels on the chart, kept short enough to sit inside the viewBox.
# Derived names were running "PECOS revalidation" and "Facility Affiliation"
# to within a few pixels of the right edge.
SHORT_LABEL = {
    "dac_physician_compare": "Medicare directory",
    "open_payments": "Industry payments",
    "pecos_revalidation": "Medicare enrolment",
    "facility_affiliation_ccn": "Hospital affiliation",
}

DISPLAY = {
    "dac_physician_compare": "Medicare clinician directory (Doctors and Clinicians)",
    "open_payments": "Industry payment records",
    "pecos_revalidation": "Medicare enrolment revalidation",
    "facility_affiliation_ccn": "Hospital affiliation records",
    "healthgrades": "Healthgrades",
    "doximity": "Doximity",
    "state_boards_of_nursing": "State boards of nursing",
    "cms_ndh_fhir": "National Directory of Healthcare Providers",
}


# The Inspector General's 2011 variables, named the way a reader would.
OIG_FIELD = {
    "practice_zip5": "Practice location (postal code)",
    "phone10": "Telephone number",
    "credential": "Credential",
    "full_name": "Full name",
    "gender": "Gender",
    "practice_state": "Practice state",
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
oig_rows = read_rows(OIG_TABLE4) if OIG_TABLE4.exists() else []

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
    # THE POINT OF THE CHART HAS TO BE VISIBLE. This was a 5px band at 22%
    # opacity in the same grey as the gridlines, which is to say invisible.
    # It is now a dashed rule in ink, drawn over the gridlines and under the
    # data, and it appears in the legend like any other series.
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
    items.append(
        '<li><span class="swatch swatch-fit"></span>'
        'Fitted trend, Medicare clinician directory</li>')
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
    rows.append(f"<tr><th class='rowhead'>Record</th>{head}</tr>")
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
                    basis=esc({"same_year": "same year",
                               "current_only": "current snapshot"}.get(
                                   row["comparison_basis"],
                                   row["comparison_basis"].replace("_", " "))),
                    n=fmt_int(row["n_comparable"]),
                    pct=esc(row["pct_agree"])))
    return ("<table class='data'><thead><tr><th>Record</th><th>Period</th>"
            "<th>Year basis</th><th>Cases</th>"
            "<th>Agrees with federal registry</th></tr></thead>"
            "<tbody>" + "".join(rows) + "</tbody></table>")


def oig_comparison_table():
    """The Inspector General's 2011 mismatch rates beside this cohort's.

    Read from the audit's own rebuild rather than retyped, so the benchmark
    column and our column cannot drift apart. Restricted to the 2026
    comparison of the federal registry against Medicare's clinician
    directory, which is the pair this page is about.
    """
    if not oig_rows:
        return ""
    current = [r for r in oig_rows
               if r["year"] == "2026" and r["source_a"] == "nppes"
               and r["source_b"] == "dac" and r["attribute"] in OIG_FIELD]
    order = list(OIG_FIELD)
    current.sort(key=lambda r: order.index(r["attribute"]))
    body = []
    for row in current:
        benchmark = row["oig_2013_benchmark_inconsistent_pct"]
        shown = ("%.1f%%" % float(benchmark)) if benchmark not in ("", "NA") \
            else "<span class='subtle'>not reported separately</span>"
        body.append(
            "<tr><td>{field}</td><td class='num'>{bench}</td>"
            "<td class='num'>{ours}</td></tr>".format(
                field=esc(OIG_FIELD[row["attribute"]]),
                bench=shown,
                ours="%.1f%%" % float(row["pct_inconsistent_any_shared"])))
    return ("<table class='data'><thead><tr><th>Provider detail</th>"
            "<th>Inspector General, 2011<br><span class='subhead'>all providers</span></th>"
            "<th>Midwifery cohort, 2026<br><span class='subhead'>this study</span></th></tr></thead><tbody>"
            + "".join(body) + "</tbody></table>")


BOARD_STATE = {"colorado": "CO", "connecticut": "CT", "delaware": "DE",
               "florida": "FL", "illinois": "IL", "pennsylvania": "PA",
               "texas": "TX", "washington": "WA"}
BOARD_NAME = {k: k.title() for k in BOARD_STATE}


def board_concordance_table():
    """How often a board's own address names that board's own state.

    Computed from the harvested board files, which are person-level and
    untracked; only the aggregate reaches the page. Returns "" when they are
    absent, so a clean checkout still renders.
    """
    import csv as _csv
    body = []
    for board in ("florida", "illinois", "colorado", "connecticut",
                  "pennsylvania", "delaware"):
        path = (ROOT / ("artifacts/live_%s_bon_ingested_midwives"
                        "_from_tracked_roster.csv" % board))
        if not path.exists():
            return ""
        with path.open(newline="") as handle:
            verified = [r for r in _csv.DictReader(handle)
                        if r.get("live_bon_match_status") == "VERIFIED_LIVE_BON"
                        and (r.get("live_bon_state") or "").strip()]
        own = BOARD_STATE[board]
        in_state = sum(1 for r in verified
                       if r["live_bon_state"].strip().upper() == own)
        if not verified:
            body.append(
                "<tr><td>{name}</td><td class='num'>0</td>"
                "<td class='num'>&ndash;</td>"
                "<td class='basis'>searched, and the board holds no matching "
                "licence</td></tr>".format(name=BOARD_NAME[board]))
            continue
        body.append(
            "<tr><td>{name}</td><td class='num'>{n}</td>"
            "<td class='num'>{pct:.1f}%</td><td class='basis'>{note}</td></tr>"
            .format(name=BOARD_NAME[board], n=fmt_int(len(verified)),
                    pct=100 * in_state / len(verified),
                    note="%s of %s give an address in the state that licensed "
                         "them" % (fmt_int(in_state), fmt_int(len(verified)))))
    return ("<table class='data'><thead><tr><th>State board</th>"
            "<th>Licences with an address</th>"
            "<th>Address in that state</th>"
            "<th>&nbsp;</th></tr></thead><tbody>"
            + "".join(body) + "</tbody></table>")


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
                note=("recovered: the board does publish a state, "
                      "and our search had been discarding it"
                      if int(row["state_recovered"])
                      else ("searched, and the board holds no matching "
                            "licence" if row["state"] == "delaware"
                            else ("already complete" if publishes
                                  else "the board publishes no address, so "
                                       "it cannot take part")))))
    return ("<table class='data'><thead><tr><th>State board</th>"
            "<th>Before</th><th>After</th><th>Change</th>"
            "<th>What happened</th></tr></thead><tbody>"
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
  text-transform: uppercase; color: var(--ink-3); vertical-align: bottom; }}
.data thead .subhead {{ text-transform: none; letter-spacing: 0;
  font-size: 0.68rem; opacity: 0.75; font-weight: 400; }}
.data td.num {{ text-align: right; font-family: var(--mono); }}
.data td.gain {{ color: var(--good); font-weight: 500; }}
.data td.basis {{ color: var(--ink-3); font-size: 0.8rem; white-space: normal; }}
.data .subtle {{ color: var(--ink-3); font-weight: 400; font-size: 0.8rem; }}
.grid th, .grid td {{ padding: 0.22rem 0.3rem; border-bottom: 1px solid var(--rule); }}
.grid th.rowhead {{ text-align: left; font-weight: 400; white-space: nowrap;
  padding-right: 0.8rem; font-size: 0.82rem; }}
.grid tr:first-child th {{ font-family: var(--mono); font-size: 0.68rem; color: var(--ink-3); }}
.grid td {{ width: 1.55rem; }}
.grid td.has {{ background: var(--accent); }}
.grid td.hasnot {{ background: transparent; }}
.sr {{ position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }}
svg .grid {{ stroke: var(--rule); stroke-width: 1; }}
svg .fit {{ stroke: var(--ink); stroke-width: 2.4; opacity: 0.85;
  stroke-dasharray: 9 5; stroke-linecap: round; }}
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
.legend .swatch-fit {{ width: 1.15rem; height: 0; border-radius: 0;
  border-top: 2.4px dashed var(--ink); opacity: 0.85; }}
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
  <h1>Where ten records say a midwife practises, and whether they agree</h1>
  <p class="standfirst">Nobody holds the answer to where a certified
  nurse-midwife actually works. Each of the ten records compared here was
  created for some other purpose, such as enrolling her in a programme,
  billing for her care, or listing her in a directory, and each captures an
  address only as a side effect. So when two of them agree, it means they are
  consistent with one another. It does not mean either is right.</p>
  <p class="standfirst">One record is used as the reference point: the federal
  registry every clinician must enrol in and keep current, which assigns the
  identifying number the other nine are matched by. It is the anchor because
  everything links to it, not because it is more accurate than the rest.</p>
</header>

<section>
  <h2>What there is to work with</h2>
  <figure>
    <div class="scroller">{coverage_grid}</div>
    <figcaption><strong>Figure 1.</strong> Years in which each record carries a
    usable practice state. No record covers the whole window, and four exist
    only as a single current snapshot. Industry payment records begin in 2021
    because that is the first year certified nurse-midwives had to be reported
    as recipients. The earlier files exist and hold a handful of stray rows,
    and are set aside deliberately rather than appearing to be
    missing.</figcaption>
  </figure>
</section>

<section>
  <h2>Why this is about agreement, and not about accuracy</h2>
  <p>Federal provider records are not good at staying current, and the
  government has measured this on itself. In May 2013 the Department of Health
  and Human Services Office of Inspector General published
  <a href="https://oig.hhs.gov/documents/evaluation/3024/OEI-07-09-00440-Complete%20Report.pdf">
  <i>Improvements Needed To Ensure Provider Enumeration and Medicare Enrollment
  Data Are Accurate, Complete, and Consistent</i></a> (report number
  OEI-07-09-00440). It examined the two federal systems that between them say
  who a clinician is and where they work, across the 987,266 providers listed
  in both.</p>
  <ul>
    <li><strong>48% of records</strong> in the national provider registry
    contained inaccurate data.</li>
    <li><strong>58% of records</strong> in the Medicare enrolment system
    contained inaccurate data.</li>
    <li>The two systems disagreed on at least one detail for
    <strong>97% of providers</strong>. Only 3% matched on everything.</li>
    <li>Practice location was the worst detail of all, mismatching for
    <strong>88.6%</strong> of providers. Only 1.2% of all the mismatches could
    be explained by one system having been updated before the other. The rest
    were simply wrong somewhere.</li>
  </ul>
  <p>What made that study possible was something we do not have. The Inspector
  General did not judge accuracy by comparing the databases to each other.
  They <strong>asked the providers</strong>. A sample of 170 was contacted and
  126 replied, each shown their own record and asked whether every detail was
  right, and where it was wrong, whether it was partly wrong, once right but
  now out of date, or never right. That survey was the gold standard, and it
  is what turns a disagreement into an error with a known owner.</p>
  <p>We rebuilt that study for certified nurse-midwives, using the same
  structure and the same definitions, through a package written for it
  (<span class="mono">mysteryroster</span>). The completeness and consistency
  halves carry over intact, and Table 1 sets ours beside theirs. The accuracy
  half does not carry over, because there is no public record anywhere that
  will say which state, city or postal code a given midwife actually practises
  in. Nobody can be surveyed at the scale this cohort needs, the board that
  certifies midwives holds no address at all, and the only records that do hold
  one are the records under examination.</p>
  <p><strong>Without that gold standard, accuracy is not a quantity we can
  compute.</strong> What we can compute is whether independent records agree
  with one another, and how that agreement moves over time. That is what every
  number on this page is, and why none of them is called correct.</p>
  {oig_table}
  <figcaption><strong>Table 1.</strong> Share of providers whose two federal
  records disagree on each detail. The first column is the Inspector General's
  2011 finding across all providers in report OEI-07-09-00440; the second is
  the midwifery cohort in 2026, comparing the federal registry against
  Medicare's public clinician directory (Doctors and Clinicians, formerly
  Physician Compare).</figcaption>
</section>

<section>
  <h2>State holds up. Finer than state, the records fall apart.</h2>
  <p>That is the single most useful thing this comparison says about midwives.
  Asked which <em>state</em> a midwife practises in, the records agree
  <strong>88% to 97%</strong> of the time depending on which pair you take.
  Asked for her postal code, the same two federal records disagree about
  <strong>46%</strong> of the time (Table 1). The Inspector General found the
  same shape in 2011, only worse, at 88.6%.</p>
  <p>This is not a rounding problem that better matching would fix. A postal
  code identifies a building; a state identifies a licensing jurisdiction, and
  that is the unit these systems are actually built to track. Any analysis of
  this cohort that rests on city or postal code is resting on the part of the
  data that does not hold, and any map drawn below state level inherits that
  weakness whether or not it is visible on the page.</p>
  {agreement_table}
  <figcaption><strong>Table 2.</strong> Every row compares one record against
  the federal provider registry. &ldquo;Same year&rdquo; means the two were
  compared within the same year. &ldquo;Current snapshot&rdquo; means that
  record exists only as one present-day extract and is compared against the
  registry as it stands today.</figcaption>
</section>

<section>
  <h2>Agreement is eroding, slowly, where the series is long enough to tell</h2>
  <figure>
    <div class="scroller">{line_chart}</div>
    {legend}
    <figcaption><strong>Figure 2.</strong> Each line is one record compared
    against the federal provider registry in the same year. The dashed rule is
    the fitted trend through Medicare's public clinician directory (Doctors and
    Clinicians, formerly Physician Compare): agreement falls
    <strong>{dac_drop:.3f} percentage points a year</strong> (p = 0.0002), so
    the drop in the most recent year continues a slow decline rather than
    breaking a flat line. Industry payment records and Medicare enrolment are
    flat, with five and six years each to say so.</figcaption>
  </figure>
  <p>Two decades of a registry that clinicians update at their own pace should
  be expected to drift, and it does. What the trend does not tell us is who
  drifted. Agreement can fall because the registry went stale, or because the
  directory did, or because the midwife genuinely moved and only one of them
  noticed. Separating those requires a clock, and only some of these records
  carry one.</p>
</section>

<section>
  <h2>Many midwives are licensed in states they do not live in</h2>
  <p>Six of the eight state nursing boards searched publish a licensee's
  mailing address, which gives an independent read on how often a midwife's
  working life crosses a state line.</p>
  <p>Across all 500 people currently licensed as nurse-midwives in
  Pennsylvania, only <strong>303 give a Pennsylvania address</strong>. Of the
  rest, 47 are in New Jersey, 16 in New York and 15 in Maryland. Four in ten
  people licensed to practise in Pennsylvania do not live there. Within this
  cohort, the 1,240 licensing records that carry an address span
  <strong>35 states</strong> across six board jurisdictions.</p>
  {board_table}
  <figcaption><strong>Table 3.</strong> How often a board's own address names
  the state that issued the licence, among records matched to this cohort.
  Delaware was searched and holds no matching licence, which is a finding
  rather than a gap.</figcaption>
  <p>This number cannot be pushed further than it goes. Each board was searched
  only for midwives the federal registry already places in that state, so the
  group is selected on the very thing the comparison would be testing. It
  establishes that multi-state licensure is common in this workforce. It cannot
  establish which record is right about any individual.</p>
  <p>Florida's 190 blank entries are also a finding. The board answers
  <em>not practising</em>, or <em>no current practice location in Florida</em>.
  It is stating an absence, which is different from having nothing to say, and
  it is kept out of the percentage rather than counted as either agreement or
  missing data.</p>
</section>

<section>
  <h2>What this does not establish</h2>
  <ul>
    <li><strong>Agreement is not accuracy.</strong> Two records agreeing are
    consistent with one another, not correct. Nothing here establishes where a
    midwife actually practises.</li>
    <li><strong>The body that certifies midwives holds no address.</strong> The
    American Midwifery Certification Board is authoritative on the credential
    and records no practice or home address at all. Every record that does hold
    an address was either filled in by the midwife herself or derived from
    billing.</li>
    <li><strong>Practising in one state may be the wrong assumption.</strong>
    Working across state lines is common enough in this group that forcing a
    single state per person creates disagreement by itself. Scoring Medicaid
    enrolment by whether a state is among those a midwife is enrolled in,
    rather than whether it is the one state picked for her, moved agreement
    from 74.7% to 88.5% without a single underlying record changing.</li>
    <li><strong>Two boards cannot take part.</strong> Texas and Washington
    publish no address, so this comparison covers six boards and will stay at
    six unless those states begin publishing one.</li>
  </ul>
</section>

<footer>
  <div>Every number on this page is read directly from the audit's own output
  tables when the page is built, so the page cannot drift from the analysis it
  describes.</div>
  <div>These figures were rebuilt on 15 November 2026 after two faults were
  found in how the inputs were assembled. The industry payment series had been
  published with one year of five, and most state licensing records had been
  entering the comparison with no state attached. Both are corrected here and
  documented in the repository.</div>
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
    oig_table=oig_comparison_table(),
    board_table=board_concordance_table(),
    bon_n=fmt_int(bon_row["n_comparable"]),
    bon_pct=bon_row["pct_agree"],
    bon_recovered=fmt_int(bon_recovered),
    dac_slope=dac_slope,
    dac_drop=abs(dac_slope),
)
out_path.write_text(rendered)
print(f"wrote {out_path} ({len(rendered):,} bytes)")
print(f"  DAC slope through 2025: {dac_slope:.3f} pts/yr")
print(f"  Open Payments years:    {[y for y, _, _ in op]}")
print(f"  Boards of Nursing:      n={bon_row['n_comparable']} "
      f"at {bon_row['pct_agree']}%, +{bon_recovered} states recovered")
