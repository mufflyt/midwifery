#!/usr/bin/env python3
# =============================================================================
# Live Colorado BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# The first real state added after the 2026-08-17/2026-09-11 fabrication
# findings (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md): every purported
# multi-state BON license number this project previously reported for any
# state other than Washington was synthesized from certification_number, not
# observed. This script follows harvest_live_wa_bon_from_tracked_roster.py's
# pattern exactly -- a real HTTP request to a real state open-data API, honest
# failure on error, and name-based matching against the tracked cohort -- so a
# second state can be added without re-introducing that defect.
#
# Source: Colorado Information Marketplace (Socrata), dataset 7s5z-vewr,
# "Professional and Occupational Licenses in Colorado," published by DORA's
# Division of Professions and Occupations and updated nightly. Confirmed via
# direct API query (2026-09-11): licensetype=APN has a subcategory field, and
# subcategory=CNM returns exactly 932 current Certified Nurse-Midwife
# licensees -- the CNM-specific slice of Colorado's Advanced Practice Nurse
# credential, analogous to WA DOH's `credentialtype like '%Midwife%'` filter.
# https://data.colorado.gov/resource/7s5z-vewr.json
#
# Matched by last+first name (same key scheme as the WA script) against
# nppes_state == "CO" in the tracked FROZEN linkage -- NOT a certification-
# number join, because DORA's dataset has no AMCB or NPI identifier at all.
# Name matching is imperfect (misses a hyphenated or maiden-name mismatch,
# can over-match a common name); this script reports what it found as its own
# result, not a confirmation of AMCB/NPPES identity.
# =============================================================================
import csv
import json
import urllib.parse
import urllib.request

print("=== Live Colorado BON cross-reference (tracked-roster cohort) ===")

CO_API = "https://data.colorado.gov/resource/7s5z-vewr.json"
CO_QUERY = {
    "licensetype": "APN",
    "subcategory": "CNM",
    "$limit": "5000",
}
co_url = CO_API + "?" + urllib.parse.urlencode(CO_QUERY)
req = urllib.request.Request(co_url, headers={"User-Agent": "Mozilla/5.0"})

live_co_records = []
try:
    with urllib.request.urlopen(req, timeout=30) as response:
        live_co_records = json.loads(response.read().decode("utf-8"))
    print(f"Successfully streamed {len(live_co_records):,} live CO CNM license records.")
except Exception as e:
    print(f"Error fetching live CO BON data: {e}")
    raise SystemExit(1)

# Index live CO records by Last_First name -- same key scheme as the WA script.
co_lookup = {}
for r in live_co_records:
    fn = r.get("firstname", "").upper().strip()
    ln = r.get("lastname", "").upper().strip()
    if fn and ln:
        co_lookup.setdefault(f"{ln}_{fn}", []).append(r)

# Cross-reference against the TRACKED roster, filtered to CO.
roster_file = "artifacts/amcb_npi_linkage_FROZEN.csv"
matched_co = []
unmatched_co = []

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        st = r.get("nppes_state", "").upper().strip()
        if st != "CO":
            continue
        fn = (r.get("nppes_first_name") or r.get("first_name") or "").upper().strip()
        ln = (r.get("nppes_last_name") or r.get("last_name") or "").upper().strip()
        key = f"{ln}_{fn}"

        out = {
            "certification_number": r.get("certification_number", ""),
            "last_name": r.get("last_name", ""),
            "first_name": r.get("first_name", ""),
            "npi": r.get("npi", ""),
            "nppes_state": st,
        }
        candidates = co_lookup.get(key, [])
        if len(candidates) == 1:
            co_info = candidates[0]
            out["live_bon_credential_num"] = co_info.get("licensenumber", "")
            out["live_bon_status"] = co_info.get("licensestatusdescription", "")
            out["live_bon_exp_date"] = co_info.get("licenseexpirationdate", "")
            out["live_bon_specialty"] = co_info.get("specialty", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched_co.append(out)
        else:
            # 0 candidates: no name match at all. >1: an ambiguous common name
            # -- reported as unmatched rather than guessed, same as the WA
            # script's binary match/no-match (which never had this case
            # because it never observed a WA name collision).
            out["live_bon_credential_num"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
            out["live_bon_exp_date"] = "NA"
            out["live_bon_specialty"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
            unmatched_co.append(out)

out_csv = "artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv"
rows = matched_co + unmatched_co
if rows:
    fieldnames = list(rows[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

n_total = len(matched_co) + len(unmatched_co)
print("=========================================================================")
print("  LIVE CO BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
print(f"  Total CO-state rows in tracked roster : {n_total:,}")
if n_total:
    print(f"  Live State BON Matched                : {len(matched_co):,} ({len(matched_co)/n_total*100:.1f}%)")
print(f"  Written to: {out_csv}")
print("=========================================================================")
