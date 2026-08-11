#!/usr/bin/env python3
# =============================================================================
# CMS DAC National Downloadable File Group Practice & Birth Center Harvester
# =============================================================================
import requests
import csv
import os
import sys
import re

CMS_DAC_NATIONAL_URL = "https://data.cms.gov/provider-data/sites/default/files/resources/52c3f098d7e56028a298fd297cb0b38d_1782750575/DAC_NationalDownloadableFile.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
LOCAL_DAC_CSV = "data/CMS_DAC_NationalDownloadableFile.csv"

print("=== CMS DAC Group Practice & Birth Center Harvester ===")

# 1. Load active cohort midwife NPIs
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

print(f"Loaded {len(coh_npis)} cohort midwives.")

# 2. Download / Stream CMS DAC National Downloadable File
if not os.path.exists(LOCAL_DAC_CSV):
    print(f"Downloading CMS DAC National Downloadable File from:\n  {CMS_DAC_NATIONAL_URL}")
    r = requests.get(CMS_DAC_NATIONAL_URL, stream=True, timeout=60)
    print(f"  HTTP Status: {r.status_code}")
    if r.status_code == 200:
        with open(LOCAL_DAC_CSV, "wb") as f:
            for chunk in r.iter_content(chunk_size=2 * 1024 * 1024):
                if chunk:
                    f.write(chunk)
        print(f"Downloaded and saved to {LOCAL_DAC_CSV}.")
    else:
        sys.exit(f"Failed to download CMS DAC National File (Status {r.status_code}).")

# 3. Process Local File & Search for Group Practice Names / Birth Centers
print("\nProcessing CMS DAC National Downloadable File...")

group_matches = []
bc_group_matches = []

bc_pattern = re.compile(
    r"\b(BIRTH|BIRTHING|MIDWIFERY|MIDWIVES|MATERNITY|NATURAL BIRTH|DELIVERY|FAMILY BIRTH|COMMUNITY BIRTH|HOME BIRTH)\b",
    re.IGNORECASE
)
hosp_exclude = re.compile(r"\b(HOSPITAL|HEALTH SYSTEM|MEDICAL CENTER|MEMORIAL)\b", re.IGNORECASE)

with open(LOCAL_DAC_CSV, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    headers = reader.fieldnames
    print(f"DAC National File Headers: {headers[:15]}")
    
    for row in reader:
        npi = row.get("NPI", "").strip()
        if npi in coh_npis:
            mw = coh_npis[npi]
            org_name = row.get("Organization Legal Name", row.get("Org_LBN", row.get("Organization Name", ""))).strip()
            group_name = row.get("Group Practice PAC ID", row.get("Group_Practice_Name", "")).strip()
            sec_spec = row.get("Secondary Specialty", row.get("Primary Specialty", "")).strip()
            
            blob = f"{org_name} {group_name} {sec_spec}".upper()
            
            record = {
                "certification_number": mw["cert"],
                "npi": npi,
                "first_name": mw["first"],
                "last_name": mw["last"],
                "nppes_state": mw["state"],
                "org_legal_name": org_name,
                "group_practice_name": group_name,
                "specialty": sec_spec
            }
            group_matches.append(record)
            
            if bool(bc_pattern.search(blob)) and not bool(hosp_exclude.search(blob)):
                bc_group_matches.append(record)

print(f"\nMatch Results:")
print(f"  - Total DAC Group Practice Records Matched: {len(group_matches)}")
print(f"  - Unique Midwives Matched in DAC National File: {len(set(r['npi'] for r in group_matches))} / {len(coh_npis)}")
print(f"  - Verified Birth Center / Midwifery Group Practice Matches: {len(bc_group_matches)}")

# Save output
out_csv = "artifacts/midwife_group_practice_names.csv"
with open(out_csv, "w", newline="", encoding="utf-8") as f:
    if group_matches:
        writer = csv.DictWriter(f, fieldnames=list(group_matches[0].keys()))
        writer.writeheader()
        writer.writerows(group_matches)

print(f"\nSaved group practice names to: {out_csv}")

print("\nSample Birth Center / Midwifery Practice Matches from CMS DAC:")
for rec in bc_group_matches[:15]:
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['nppes_state']}) -> Practice/Org: {rec['org_legal_name']} | Specialty: {rec['specialty']}")
