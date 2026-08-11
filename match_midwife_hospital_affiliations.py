#!/usr/bin/env python3
# =============================================================================
# CMS Facility Affiliation Stream Processor & Midwife Hospital Linkage Engine
# =============================================================================
import requests
import csv
import io
import os
import sys

CMS_FACILITY_URL = "https://data.cms.gov/provider-data/sites/default/files/resources/b7c4080ae144663e43353a9c35cd3f53_1782750576/Facility_Affiliation.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"

# 1. Load active cohort midwife NPIs
print("=== CMS Midwife Hospital & Healthcare Facility Affiliation Engine ===")

coh_npis = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            npi = r.get("npi", "").strip()
            if npi:
                coh_npis[npi] = {
                    "cert": r.get("certification_number"),
                    "first": r.get("first_name"),
                    "last": r.get("last_name"),
                    "state": r.get("state")
                }

print(f"Loaded {len(coh_npis)} active cohort midwife NPIs.\n")

# 2. Download / Stream CMS Facility Affiliation file
local_facility_csv = "data/CMS_Facility_Affiliation.csv"
if not os.path.exists(local_facility_csv):
    print(f"Downloading CMS Facility Affiliation dataset from:\n  {CMS_FACILITY_URL}")
    r = requests.get(CMS_FACILITY_URL, stream=True, timeout=60)
    print(f"  HTTP Response Status: {r.status_code}")
    if r.status_code == 200:
        with open(local_facility_csv, "wb") as f:
            for chunk in r.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    f.write(chunk)
        print(f"Downloaded and saved to {local_facility_csv}.")
    else:
        sys.exit(f"Failed to download CMS facility affiliations (Status {r.status_code}).")

# 3. Process local CMS Facility Affiliation file
print("\nProcessing CMS Facility Affiliation dataset...")

matched_affiliations = []
matched_npis = set()

with open(local_facility_csv, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    headers = reader.fieldnames
    print(f"CMS Facility Affiliation Headers: {headers}")
    
    for row in reader:
        # Detect NPI column
        npi_col = "NPI" if "NPI" in row else ("npi" if "npi" in row else None)
        if not npi_col:
            for k in row.keys():
                if "npi" in k.lower():
                    npi_col = k
                    break
        
        npi_val = row.get(npi_col, "").strip() if npi_col else ""
        if npi_val in coh_npis:
            mw = coh_npis[npi_val]
            matched_npis.add(npi_val)
            matched_affiliations.append({
                "certification_number": mw["cert"],
                "npi": npi_val,
                "first_name": mw["first"],
                "last_name": mw["last"],
                "nppes_state": mw["state"],
                "facility_ccn": row.get("Facility CCN", row.get("Facility_CCN", row.get("CCN", ""))),
                "facility_name": row.get("Facility Name", row.get("Facility_Name", row.get("Facility", ""))),
                "facility_type": row.get("Facility Type", row.get("Facility_Type", "")),
                "facility_city": row.get("City", row.get("Facility_City", "")),
                "facility_state": row.get("State", row.get("Facility_State", ""))
            })

print(f"\nMatch Yield:")
print(f"  - Total Matched Midwife NPIs: {len(matched_npis)} / {len(coh_npis)} ({len(matched_npis)/len(coh_npis)*100:.2f}%)")
print(f"  - Total Hospital / Facility Affiliation Records: {len(matched_affiliations)}")

# Save output
out_csv = "artifacts/midwife_hospital_affiliations.csv"
with open(out_csv, "w", newline="", encoding="utf-8") as f:
    if matched_affiliations:
        writer = csv.DictWriter(f, fieldnames=list(matched_affiliations[0].keys()))
        writer.writeheader()
        writer.writerows(matched_affiliations)

print(f"\nSaved hospital affiliation linkages to: {out_csv}")

# Display top 5 sample matches
print("\nSample Midwife Hospital Linkages:")
for rec in matched_affiliations[:5]:
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['nppes_state']}) -> Facility: {rec['facility_name']} (CCN: {rec['facility_ccn']})")
