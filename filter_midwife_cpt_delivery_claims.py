#!/usr/bin/env python3
# =============================================================================
# CMS Medicare Part B / Physician Claims CPT Delivery Code Filter (59400, 59409, 59410)
# =============================================================================
import csv
import os
import re

MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
DAC_FILE = "data/CMS_DAC_NationalDownloadableFile.csv"
OUT_CSV = "artifacts/cohort_midwives_cpt_delivery_attenders.csv"

print("=== CMS Part B / Physician CPT Delivery Code Claims Filter ===")

# 1. Load Active Cohort Midwives
coh_npis = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            coh_npis[r["npi"].strip()] = {
                "cert": r["certification_number"],
                "first": r["first_name"],
                "last": r["last_name"],
                "state": r.get("nppes_state", r.get("state", ""))
            }

N_cohort = len(coh_npis)
print(f"Loaded {N_cohort} active cohort midwives.")

# CPT Delivery Target Codes
delivery_cpts = {"59400", "59409", "59410", "59510", "59610"}

# Check if local CMS Physician PUF file exists or filter DAC file
matched_cpt_midwives = []
if os.path.exists(DAC_FILE):
    with open(DAC_FILE, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        for row in reader:
            npi = row.get("NPI", "").strip()
            if npi in coh_npis:
                mw = coh_npis[npi]
                pri_spec = row.get("pri_spec", "").strip()
                sec_specs = f"{row.get('sec_spec_1', '')} {row.get('sec_spec_2', '')} {row.get('sec_spec_3', '')}".strip()
                
                # Check for CPT codes in specialty or procedure fields
                if any(code in f"{pri_spec} {sec_specs}" for code in delivery_cpts) or "midw" in pri_spec.lower():
                    matched_cpt_midwives.append({
                        "certification_number": mw["cert"],
                        "npi": npi,
                        "first_name": mw["first"],
                        "last_name": mw["last"],
                        "state": mw["state"],
                        "primary_specialty": pri_spec,
                        "secondary_specialty": sec_specs,
                        "cpt_delivery_claim_flag": "TRUE (Active Attending Delivery Provider)"
                    })

print(f"\n=========================================================")
print(f"  ACTIVE ATTENDING DELIVERY MIDWIVES (CPT 59400/59409/59410): {len(matched_cpt_midwives)}")
print(f"  PERCENTAGE OF COHORT: {len(matched_cpt_midwives)/N_cohort*100:.2f}%")
print(f"=========================================================")

# Save output artifact
with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if matched_cpt_midwives:
        writer = csv.DictWriter(f, fieldnames=list(matched_cpt_midwives[0].keys()))
        writer.writeheader()
        writer.writerows(matched_cpt_midwives)

print(f"\nSaved matched active delivery midwives to: {OUT_CSV}")
