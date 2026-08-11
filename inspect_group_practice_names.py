#!/usr/bin/env python3
# =============================================================================
# Group Practice & Organization Business Name Extractor
# =============================================================================
import requests
import csv
import re

CMS_DAC_URL = "https://data.cms.gov/provider-data/sites/default/files/resources/b7c4080ae144663e43353a9c35cd3f53_1782750576/Facility_Affiliation.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"

# Load cohort NPIs
coh_npis = set()
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            coh_npis.add(r["npi"].strip())

print(f"Loaded {len(coh_npis)} cohort NPIs.")

# Check CMS Facility Affiliation file for group names or facility types
bc_count = 0
with open("data/CMS_Facility_Affiliation.csv", "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    print("Facility Affiliation Headers:", reader.fieldnames)
    for r in reader:
        npi = r.get("NPI", "").strip()
        if npi in coh_npis:
            ftype = r.get("facility_type", "")
            if "birth" in ftype.lower() or "clinic" in ftype.lower():
                bc_count += 1

print(f"CMS DAC Birth Center / Clinic Linkages: {bc_count}")
