#!/usr/bin/env python3
# =============================================================================
# Live Texas BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# Third real state added after the 2026-08-17/2026-09-11 fabrication findings
# (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md). Follows
# harvest_live_co_bon_from_tracked_roster.py's pattern exactly -- a real HTTP
# request to a real state open-data API, honest failure on error, and
# name-based matching against the tracked cohort.
#
# Source: Texas Board of Nursing (via data.texas.gov / Socrata), dataset
# jnzg-cr4w, "APRN-Active." Confirmed via direct API query (2026-09-12):
# apn_category has a genuine "NURSE MIDWIFE" value (754 current records,
# distinct from NURSE PRACTITIONER/CLINICAL NURSE SPECIALIST/NURSE
# ANESTHETIST), and -- unlike Colorado, which required a second dataset
# (RXN/subcategory=CNM) joined by a contact ID -- prescriptive authority is
# tracked on the SAME row via apn_prescriptive_authority_status: of the 754
# nurse-midwife records, 704 (93.4%) show "Active." No cross-agency join
# (e.g. against the Texas Medical Board's separately-published Prescriptive
# Delegation dataset) is needed for this.
# https://data.texas.gov/resource/jnzg-cr4w.json
#
# Matched by last+first name (same key scheme as the WA/CO scripts) against
# nppes_state == "TX" in the tracked FROZEN linkage -- NOT a license-number or
# NPI join, because this Texas dataset carries neither an AMCB nor an NPI
# identifier. Name matching is imperfect (misses a hyphenated or maiden-name
# mismatch, can over-match a common name); this script reports what it found
# as its own result, not a confirmation of AMCB/NPPES identity.
# =============================================================================
import csv
import json
import urllib.parse
import urllib.request

print("=== Live Texas BON cross-reference (tracked-roster cohort) ===")

TX_API = "https://data.texas.gov/resource/jnzg-cr4w.json"
TX_QUERY = {
    "apn_category": "NURSE MIDWIFE",
    "$limit": "5000",
}
tx_url = TX_API + "?" + urllib.parse.urlencode(TX_QUERY)
req = urllib.request.Request(tx_url, headers={"User-Agent": "Mozilla/5.0"})

live_tx_records = []
try:
    with urllib.request.urlopen(req, timeout=30) as response:
        live_tx_records = json.loads(response.read().decode("utf-8"))
    print(f"Successfully streamed {len(live_tx_records):,} live TX nurse-midwife APRN records.")
except Exception as e:
    print(f"Error fetching live TX BON data: {e}")
    raise SystemExit(1)

# Index live TX records by Last_First name -- same key scheme as the CO script.
tx_lookup = {}
for r in live_tx_records:
    fn = r.get("first_name", "").upper().strip()
    ln = r.get("last_name", "").upper().strip()
    if fn and ln:
        tx_lookup.setdefault(f"{ln}_{fn}", []).append(r)

# Cross-reference against the TRACKED roster, filtered to TX.
roster_file = "artifacts/amcb_npi_linkage_FROZEN.csv"
matched_tx = []
unmatched_tx = []

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        st = r.get("nppes_state", "").upper().strip()
        if st != "TX":
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
        candidates = tx_lookup.get(key, [])
        if len(candidates) == 1:
            tx_info = candidates[0]
            out["live_bon_license_number"] = tx_info.get("license_number", "")
            out["live_bon_status"] = tx_info.get("apn_status", "")
            out["live_bon_apn_sub_category"] = tx_info.get("apn_sub_category", "")
            out["live_rxn_authority_number"] = tx_info.get("apn_prescriptive_authority_number", "")
            out["live_rxn_authority_status"] = tx_info.get("apn_prescriptive_authority_status", "")
            out["live_rxn_authority_exp_date"] = tx_info.get("apn_prescriptive_authority_expiration_date", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched_tx.append(out)
        else:
            # 0 candidates: no name match at all. >1: an ambiguous common name
            # -- reported as unmatched rather than guessed, same as the CO
            # script's handling of name collisions.
            out["live_bon_license_number"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
            out["live_bon_apn_sub_category"] = "NA"
            out["live_rxn_authority_number"] = "NA"
            out["live_rxn_authority_status"] = "NA"
            out["live_rxn_authority_exp_date"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
            unmatched_tx.append(out)

out_csv = "artifacts/live_texas_bon_ingested_midwives_from_tracked_roster.csv"
rows = matched_tx + unmatched_tx
if rows:
    fieldnames = list(rows[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

n_total = len(matched_tx) + len(unmatched_tx)
n_rxn_active = sum(1 for r in matched_tx if r["live_rxn_authority_status"] == "Active")
print("=========================================================================")
print("  LIVE TX BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
print(f"  Total TX-state rows in tracked roster : {n_total:,}")
if n_total:
    print(f"  Live State BON Matched                : {len(matched_tx):,} ({len(matched_tx)/n_total*100:.1f}%)")
if matched_tx:
    print(f"  Of those, Active RXN authority         : {n_rxn_active:,} ({n_rxn_active/len(matched_tx)*100:.1f}%)")
print(f"  Written to: {out_csv}")
print("=========================================================================")
