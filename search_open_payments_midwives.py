#!/usr/bin/env python3
# =============================================================================
# CMS Open Payments (Sunshine Act) Midwife Employer & Facility Harvester
# =============================================================================
import requests
import json
import csv
import sys

MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
OUT_CSV = "artifacts/open_payments_midwife_employers.csv"

print("=== CMS Open Payments Midwife Employer & Facility Harvester ===")

# 1. Load active cohort midwife NPIs
coh_npis = set()
coh_dict = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            npi = r["npi"].strip()
            coh_npis.add(npi)
            coh_dict[npi] = {
                "cert": r["certification_number"],
                "first": r["first_name"],
                "last": r["last_name"],
                "state": r.get("nppes_state", r.get("state", ""))
            }

print(f"Loaded {len(coh_npis)} active cohort midwives.")

# 2. Check Open Payments API metastore or Socrata endpoint
catalog_url = "https://openpaymentsdata.cms.gov/api/1/metastore/schemas/dataset/items"
headers = {"User-Agent": "Mozilla/5.0"}

try:
    r = requests.get(catalog_url, headers=headers, timeout=15)
    print(f"CMS Open Payments Catalog HTTP Status: {r.status_code}")
    if r.status_code == 200:
        items = r.json()
        print(f"Total Open Payments Datasets Available: {len(items)}")
        for item in items[:10]:
            print(f"  - Title: {item.get('title')}")
            dist = item.get("distribution", [])
            if dist:
                print(f"    Download URL: {dist[0].get('downloadURL')}")
except Exception as e:
    print(f"Error querying Open Payments catalog API: {e}")
