#!/usr/bin/env python3
import csv
import re

MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"

# Load cohort
coh = set()
with open(MIDWIVES_FILE, "r") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            coh.add(r["certification_number"])

print(f"Loaded {len(coh)} active midwives.")

# Check healthgrades_midwives.csv
if os_exists := True:
    try:
        with open("healthgrades_midwives.csv", "r") as f:
            reader = csv.DictReader(f)
            print("HG Midwives headers:", reader.fieldnames)
            bc_count = 0
            for r in reader:
                if r.get("certification_number") in coh:
                    name = r.get("hg_name", "")
                    url = r.get("hg_url", "")
                    if "birth" in url.lower() or "midwi" in url.lower():
                        bc_count += 1
            print("HG Midwives birth/midwife URL matches:", bc_count)
    except Exception as e:
        print("Error:", e)
