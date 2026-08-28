#!/usr/bin/env python3
# =============================================================================
# Live Washington BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# A substitute for harvest_live_state_bon_apis.py, not a replacement of it.
# That script's cohort (artifacts/cohort_midwife_facility_attributions_final_v4.csv)
# is gitignored, person-level, and absent -- and rebuilding it means redoing
# core AMCB<->NPI identity linkage plus four separate CMS/registry data
# domains (hospital attribution, CABC birth centers, CPT claims, Open
# Payments), not a script run. See docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md
# and the 2026-08-28 session that investigated this.
#
# This script asks the same real question -- which midwives in this project's
# cohort hold a genuine, live-verified Washington DOH credential -- against a
# DIFFERENT cohort source: artifacts/scraped_50_states_and_dc_midwives_master.csv
# (already tracked). It is NOT expected to reproduce the original's 374-match
# figure exactly: a different cohort, matched the same way (last+first name),
# can plausibly find a different number of matches. Treat this output's count
# as its own result, not a confirmation or contradiction of the original.
# =============================================================================
import csv
import json
import urllib.request

print("=== Live Washington BON cross-reference (tracked-roster cohort) ===")

# 1. Fetch Live Washington State Midwife Credentials via Socrata API
wa_url = "https://data.wa.gov/resource/qxh8-f4bd.json?$where=credentialtype%20like%20%27%25Midwife%25%27&$limit=5000"
req = urllib.request.Request(wa_url, headers={"User-Agent": "Mozilla/5.0"})

live_wa_records = []
try:
    with urllib.request.urlopen(req, timeout=30) as response:
        live_wa_records = json.loads(response.read().decode("utf-8"))
    print(f"Successfully streamed {len(live_wa_records):,} live WA State midwife license records.")
except Exception as e:
    print(f"Error fetching live WA BON data: {e}")
    raise SystemExit(1)

# Index live WA records by Last_First name -- same key scheme as the original
# script, so the matching LOGIC is unchanged; only the cohort source differs.
wa_lookup = {}
for r in live_wa_records:
    fn = r.get("firstname", "").upper().strip()
    ln = r.get("lastname", "").upper().strip()
    if fn and ln:
        wa_lookup[f"{ln}_{fn}"] = r

# 2. Cross-reference against the TRACKED roster, filtered to WA
roster_file = "artifacts/scraped_50_states_and_dc_midwives_master.csv"
matched_wa = []
unmatched_wa = []

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        st = r.get("nppes_state", "").upper().strip()
        if st != "WA":
            continue
        fn = r.get("first_name", "").upper().strip()
        ln = r.get("last_name", "").upper().strip()
        key = f"{ln}_{fn}"

        out = {
            "certification_number": r.get("certification_number", ""),
            "last_name": r.get("last_name", ""),
            "first_name": r.get("first_name", ""),
            "npi": r.get("npi", ""),
            "nppes_state": st,
        }
        if key in wa_lookup:
            wa_info = wa_lookup[key]
            out["live_bon_credential_num"] = wa_info.get("credentialnumber", "")
            out["live_bon_status"] = wa_info.get("status", "")
            out["live_bon_exp_date"] = wa_info.get("expirationdate", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched_wa.append(out)
        else:
            out["live_bon_credential_num"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON"
            out["live_bon_exp_date"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED"
            unmatched_wa.append(out)

out_csv = "artifacts/live_washington_bon_ingested_midwives_from_tracked_roster.csv"
rows = matched_wa + unmatched_wa
if rows:
    fieldnames = list(rows[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

n_total = len(matched_wa) + len(unmatched_wa)
print("=========================================================================")
print("  LIVE WA BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
print(f"  Total WA-state rows in tracked roster : {n_total:,}")
if n_total:
    print(f"  Live State BON Matched                : {len(matched_wa):,} ({len(matched_wa)/n_total*100:.1f}%)")
print(f"  Written to: {out_csv}")
print("=========================================================================")
