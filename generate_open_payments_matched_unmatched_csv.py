#!/usr/bin/env python3
# =============================================================================
# Open Payments Matched vs Unmatched Full Cohort Master Dataset
# =============================================================================
import csv

V4_FILE = "artifacts/cohort_midwife_facility_attributions_final_v4.csv"
YIELD_FILE = "artifacts/cohort_midwives_open_payments_postmastr_final_yield.csv"
OUT_CSV = "artifacts/open_payments_midwives_matched_vs_unmatched.csv"

print("=== Generating Open Payments Matched vs Unmatched Master Dataset ===")

# Load Postmastr Facility Matches
postmastr_matches = {}
with open(YIELD_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        npi = r.get("midwife_npi", "").strip()
        if npi:
            postmastr_matches[npi] = {
                "op_address": r.get("open_payments_address", ""),
                "matched_facility_name": r.get("matched_facility_name", ""),
                "matched_facility_id": r.get("matched_facility_id", ""),
                "facility_linkage_type": r.get("facility_linkage_type", "")
            }

# Load Master v4
rows = []
n_matched = 0
n_unmatched = 0

with open(V4_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        npi = r.get("npi", "").strip()
        has_op = r.get("has_open_payments_record", "").upper() == "TRUE"
        
        pm = postmastr_matches.get(npi, {})
        
        if has_op or pm:
            status = "MATCHED (Open Payments / Facility Linked)"
            n_matched += 1
        else:
            status = "UNMATCHED (No Open Payments Record)"
            n_unmatched += 1
            
        rows.append({
            "certification_number": r.get("certification_number", ""),
            "npi": npi,
            "first_name": r.get("first_name", ""),
            "last_name": r.get("last_name", ""),
            "state": r.get("nppes_state", r.get("state", "")),
            "open_payments_match_status": status,
            "open_payments_practice_address": pm.get("op_address", r.get("op_address", "")),
            "matched_facility_or_employer": pm.get("matched_facility_name", r.get("op_profile_match", "")),
            "matched_facility_id": pm.get("matched_facility_id", ""),
            "facility_linkage_type": pm.get("facility_linkage_type", ""),
            "has_cpt_delivery_claims": r.get("has_cpt_delivery_claim", ""),
            "refined_clinical_practice_setting": r.get("refined_clinical_setting", "")
        })

print(f"Total Cohort Midwives: {len(rows):,}")
print(f"  - Matched in Open Payments / Facilities: {n_matched:,} ({n_matched/len(rows)*100:.2f}%)")
print(f"  - Unmatched: {n_unmatched:,} ({n_unmatched/len(rows)*100:.2f}%)")

with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if rows:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

print(f"Saved matched vs unmatched dataset to: {OUT_CSV}")
