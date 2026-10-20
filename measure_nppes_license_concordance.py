#!/usr/bin/env python3
"""Measure state license reporting and board concordance for the matched cohort.

Scope: the `primary_midwifery` linkage tier in `artifacts/amcb_npi_linkage_FROZEN.csv`
-- the certificants with a confirmed midwifery-taxonomy NPI match (14,959 of
22,357, ~66.9%, close to README's reported 66.2% "confirmed midwifery taxonomy"
ceiling; the small gap is vintage/rounding, not a different population).

License number and license state are NOT in the FROZEN linkage or in
nppes_candidates.csv -- fetch_npi_candidates.py's build_candidate_rows() never
extracted them. They ARE in the raw NPI Registry API response already cached in
nppes_api_cache.jsonl, under each taxonomy entry's `license`/`state` fields
(NOT the top-level `identifiers` array, which carries Medicaid/Medicare billing
identifiers, not nursing licenses -- confirmed by inspection). A person can
carry several taxonomy entries (e.g. both "Registered Nurse" and "Advanced
Practice Midwife") that repeat the SAME license number; this script dedupes to
distinct (license_number, state) pairs per NPI before counting.

Board concordance is checked only for the subset of the matched cohort also
found in this repo's three genuine board-of-nursing pulls (WA DOH, CO DORA, TX
BON; `live_bon_match_status == "VERIFIED_LIVE_BON"`), joined by
certification_number. NPPES and board license-number formats differ
cosmetically (e.g. NPPES "AP61332308" vs WA DOH "ARNP.AP.61332308-CNM") --
confirmed by inspection, the board format wraps the same core identifier with a
credential-type prefix/suffix. Comparison strips all non-alphanumeric
characters and checks substring containment either direction, state-to-state.

Output: artifacts/nppes_license_concordance.csv (one row per matched
certificant) and artifacts/nppes_license_concordance.csv.provenance.json.
"""
import csv
import hashlib
import json
import re
import sys
from collections import defaultdict

FROZEN = "artifacts/amcb_npi_linkage_FROZEN.csv"
CACHE = "nppes_api_cache.jsonl"
OUT = "artifacts/nppes_license_concordance.csv"

BON_FILES = {
    "WA": ("artifacts/live_washington_bon_ingested_midwives_from_tracked_roster.csv", "live_bon_credential_num"),
    "CO": ("artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv", "live_bon_credential_num"),
    "TX": ("artifacts/live_texas_bon_ingested_midwives_from_tracked_roster.csv", "live_bon_license_number"),
}


def normalize(s):
    return re.sub(r"[^A-Z0-9]", "", (s or "").upper())


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_matched_cohort():
    rows = []
    with open(FROZEN, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["linkage_tier"] == "primary_midwifery":
                rows.append(row)
    return rows


def load_license_pairs(npis):
    """npi -> set of (license_number, state) from NPPES taxonomy entries."""
    out = defaultdict(set)
    want = set(npis)
    remaining = set(want)
    with open(CACHE, encoding="utf-8") as f:
        for line in f:
            if not remaining:
                break
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            for r in rec.get("results", []):
                npi = r.get("number")
                if npi not in want:
                    continue
                for t in r.get("taxonomies") or []:
                    lic = (t.get("license") or "").strip()
                    if lic:
                        out[npi].add((lic, (t.get("state") or "").strip()))
                remaining.discard(npi)
    return out


def load_bon_truth():
    """certification_number -> {state: board_license_number}, verified rows only."""
    truth = defaultdict(dict)
    for state, (path, field) in BON_FILES.items():
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                if row.get("live_bon_match_status") != "VERIFIED_LIVE_BON":
                    continue
                lic = (row.get(field) or "").strip()
                if lic:
                    truth[row["certification_number"]][state] = lic
    return truth


def main():
    cohort = load_matched_cohort()
    npis = [r["npi"] for r in cohort if r.get("npi")]
    license_map = load_license_pairs(npis)
    bon_truth = load_bon_truth()

    rows_out = []
    n = len(cohort)
    n_with_license = 0
    n_multi = 0
    states_seen = set()
    n_board_checkable = 0
    n_board_match = 0

    for r in cohort:
        npi = r.get("npi", "")
        pairs = license_map.get(npi, set())
        has_license = len(pairs) > 0
        if has_license:
            n_with_license += 1
        if len(pairs) > 1:
            n_multi += 1
        for _, st in pairs:
            if st:
                states_seen.add(st)

        cert = r["certification_number"]
        board_states = bon_truth.get(cert)
        board_checkable = board_states is not None
        board_match = False
        if board_checkable:
            n_board_checkable += 1
            norm_nppes = {(normalize(lic), st) for lic, st in pairs}
            for st, board_lic in board_states.items():
                nb = normalize(board_lic)
                for nlic, nst in norm_nppes:
                    if nst != st or not nlic:
                        continue
                    if nb in nlic or nlic in nb:
                        board_match = True
            if board_match:
                n_board_match += 1

        full_name = (
            f"{r.get('nppes_first_name') or r.get('first_name', '')} "
            f"{r.get('nppes_last_name') or r.get('last_name', '')}"
        ).strip()

        rows_out.append({
            "certification_number": cert,
            "full_name": full_name,
            "npi": npi,
            "license_numbers": "|".join(sorted(lic for lic, _ in pairs)),
            "license_states": "|".join(sorted({st for _, st in pairs if st})),
            "n_distinct_licenses": len(pairs),
            "board_checkable": board_checkable,
            "board_license_match": board_match if board_checkable else "",
        })

    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows_out[0].keys()))
        w.writeheader()
        w.writerows(rows_out)

    def pct(k, d):
        return f"{100 * k / d:.1f}%" if d else "n/a"

    print(f"Matched cohort (linkage_tier == primary_midwifery): {n:,}")
    print(f"  Nonmissing state license number:  {n_with_license:,} ({pct(n_with_license, n)})")
    print(f"  Multiple reported licenses:        {n_multi:,} ({pct(n_multi, n)})")
    print(f"  Distinct licensing states observed: {len(states_seen)}")
    print(f"  Board-checkable (WA/CO/TX verified board hit): {n_board_checkable:,} ({pct(n_board_checkable, n)} of full cohort)")
    print(f"  Of those, NPPES license matches board record:  {n_board_match:,} ({pct(n_board_match, n_board_checkable)} of board-checkable)")

    provenance = {
        "artifact": OUT,
        "inputs": [
            {"path": FROZEN, "sha256": sha256_of(FROZEN)},
            {"path": CACHE, "sha256": sha256_of(CACHE)},
        ] + [{"path": p, "sha256": sha256_of(p)} for p, _ in BON_FILES.values()],
        "summary": {
            "n_matched_cohort": n,
            "n_with_license": n_with_license,
            "pct_with_license": round(100 * n_with_license / n, 1) if n else None,
            "n_multiple_licenses": n_multi,
            "pct_multiple_licenses": round(100 * n_multi / n, 1) if n else None,
            "n_distinct_states": len(states_seen),
            "n_board_checkable": n_board_checkable,
            "n_board_match": n_board_match,
            "pct_board_match_of_checkable": round(100 * n_board_match / n_board_checkable, 1) if n_board_checkable else None,
        },
    }
    with open(OUT + ".provenance.json", "w", encoding="utf-8") as f:
        json.dump(provenance, f, indent=2)


if __name__ == "__main__":
    main()
