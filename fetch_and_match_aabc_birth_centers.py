#!/usr/bin/env python3
# =============================================================================
# Master Freestanding Birth Center (FBC) Address & Taxonomy Harvester
# =============================================================================
import requests
import json
import csv
import re

MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
OUT_CSV = "artifacts/freestanding_birth_center_midwives_expanded.csv"

print("=== Expanded Freestanding Birth Center (FBC) Matching Engine ===")

# 1. Load active cohort midwives with full practice address
coh = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            coh[r["npi"]] = {
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
            coh[npi]["tax_code"] = r.get("taxonomy_code", "")
            coh[npi]["tax_desc"] = r.get("taxonomy_description", "")

print(f"Loaded {len(coh)} active cohort midwives.")

# 2. Comprehensive Birth Center & Midwifery Practice Regex Engine
# Detects: Birth Center, Birthing Center, Midwifery Practice, Birth Suite, Family Birth, etc.
bc_regex = re.compile(
    r"\b(BIRTH|BIRTHING|MIDWIFERY|MIDWIVES|MATERNITY|NATURAL BIRTH|DELIVERY|FAMILY BIRTH|COMMUNITY BIRTH|HOME BIRTH)\b",
    re.IGNORECASE
)

# Generic hospital words to exclude false positives (e.g. "Hospital", "Medical Center", "Health System")
hosp_exclude_regex = re.compile(
    r"\b(HOSPITAL|HEALTH SYSTEM|MEDICAL CENTER|MEMORIAL|HEALTHCARE SYSTEM|UNIV HOSPITAL)\b",
    re.IGNORECASE
)

bc_matches = []
for npi, mw in coh.items():
    blob = f"{mw.get('addr1', '')} {mw.get('addr2', '')} {mw.get('nppes_addr', '')} {mw.get('tax_desc', '')}".upper()
    
    # Condition A: Taxonomy match
    tax_hit = "261QB0900X" in mw.get("tax_code", "") or "BIRTH CENTER" in mw.get("tax_desc", "").upper()
    
    # Condition B: Keyword match without hospital exclude
    keyword_hit = bool(bc_regex.search(blob)) and not bool(hosp_exclude_regex.search(blob))
    
    if tax_hit or keyword_hit:
        bc_matches.append({
            "certification_number": mw["cert"],
            "npi": npi,
            "first_name": mw["first"],
            "last_name": mw["last"],
            "practice_address": mw.get("addr1", mw["nppes_addr"]),
            "practice_city": mw["city"],
            "practice_state": mw["state"],
            "practice_zip": mw["zip"],
            "taxonomy_description": mw.get("tax_desc", ""),
            "match_type": "Taxonomy" if tax_hit else "Practice Keyword Match"
        })

print(f"\nExpanded Birth Center & Midwifery Practice Matches: {len(bc_matches)} midwives ({len(bc_matches)/len(coh)*100:.2f}% of cohort)")

# Save output
with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if bc_matches:
        writer = csv.DictWriter(f, fieldnames=list(bc_matches[0].keys()))
        writer.writeheader()
        writer.writerows(bc_matches)

print(f"Saved expanded birth center matches to: {OUT_CSV}")

print("\nSample Expanded Matches:")
for m in bc_matches[:10]:
    print(f"  CNM {m['first_name']} {m['last_name']} ({m['practice_city']}, {m['practice_state']}) -> Address: {m['practice_address']} [{m['match_type']}]")
