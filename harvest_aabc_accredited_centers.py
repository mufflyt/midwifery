#!/usr/bin/env python3
# =============================================================================
# AABC Accredited Freestanding Birth Center Harvester & Cohort Matcher
# =============================================================================
import requests
import json
import csv
import re

MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
OUT_CSV = "artifacts/aabc_matched_birth_center_midwives.csv"

print("=== AABC Accredited Freestanding Birth Center Harvester & Matcher ===")

# 1. Load active cohort midwives with full practice address
coh = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            coh[r["npi"].strip()] = {
                "cert": r["certification_number"],
                "first": r["first_name"],
                "last": r["last_name"],
                "nppes_addr": r.get("nppes_practice_address", ""),
                "city": r.get("nppes_city", ""),
                "state": r.get("nppes_state", ""),
                "zip": r.get("nppes_zip", "")
            }

with open(GEO_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        npi = r.get("npi")
        if npi in coh:
            coh[npi]["addr1"] = r.get("practice_address_1", "")
            coh[npi]["addr2"] = r.get("practice_address_2", "")
            coh[npi]["city"] = r.get("practice_city", "")
            coh[npi]["state"] = r.get("practice_state", "")
            coh[npi]["zip"] = r.get("practice_zip", "")

print(f"Loaded {len(coh)} active cohort midwives.")

# 2. Comprehensive Freestanding Birth Center Regex & Address Matching Engine
# Searches for keywords: BIRTH CENTER, BIRTHING CENTER, MIDWIFERY BIRTH, COMMUNITY BIRTH,
# NATURAL BIRTH, FAMILY BIRTH, MATERNITY CENTER, HOME BIRTH
bc_pattern = re.compile(
    r"\b(BIRTH\s*CENTER|BIRTH\s*CENTRE|BIRTHING\s*CENTER|BIRTHING\s*HOME|MIDWIFERY\s*CENTER|MIDWIFERY\s*BIRTH|FAMILY\s*BIRTH|COMMUNITY\s*BIRTH|NATURAL\s*BIRTH|HOME\s*BIRTH|BIRTH\s*WORKS|BIRTH\s*SUITE|MATERNITY\s*CENTER)\b",
    re.IGNORECASE
)

matched_records = []
for npi, mw in coh.items():
    p1 = mw.get("addr1", "")
    p2 = mw.get("addr2", "")
    n_addr = mw.get("nppes_addr", "")
    blob = f"{p1} {p2} {n_addr}".upper()
    
    if bc_pattern.search(blob):
        matched_records.append({
            "certification_number": mw["cert"],
            "npi": npi,
            "first_name": mw["first"],
            "last_name": mw["last"],
            "practice_address": p1 if p1 else n_addr,
            "practice_city": mw["city"],
            "practice_state": mw["state"],
            "practice_zip": mw["zip"],
            "matched_facility_text": blob
        })

print(f"\nTotal Birth Center & Freestanding Birthing Facility Matches: {len(matched_records)}")

# Save output
with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if matched_records:
        writer = csv.DictWriter(f, fieldnames=list(matched_records[0].keys()))
        writer.writeheader()
        writer.writerows(matched_records)

print(f"Saved matched birth center midwives to: {OUT_CSV}")

print("\nSample Matched Birth Center Midwives:")
for rec in matched_records[:10]:
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['practice_city']}, {rec['practice_state']}) -> {rec['practice_address']}")
