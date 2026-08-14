#!/usr/bin/env python3
# =============================================================================
# Louisiana State Board of Nursing (LSBN) Verified Midwife Roster
# =============================================================================
import csv

v4_file = "artifacts/cohort_midwives_tier1_tier2_bon_validated.csv"
la_records = []

with open(v4_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("nppes_state", "").upper() == "LA" or r.get("state", "").upper() == "LA":
            la_records.append({
                "npi": r.get("npi"),
                "first_name": r.get("first_name"),
                "last_name": r.get("last_name"),
                "amcb_cert": r.get("certification_number"),
                "city": r.get("nppes_city"),
                "state": "LA",
                "zip": r.get("nppes_zip"),
                "lsbn_status": r.get("bon_verification_status"),
                "cpt_attender": r.get("has_cpt_delivery_claim"),
                "attributed_hospital": r.get("attributed_hospital_name")
            })

out_csv = "artifacts/louisiana_cnm_board_roster.csv"
if la_records:
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(la_records[0].keys()))
        writer.writeheader()
        writer.writerows(la_records)

print(f"=== Successfully exported {len(la_records)} Louisiana CNM Roster Records to: {out_csv} ===")
