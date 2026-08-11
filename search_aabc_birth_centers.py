#!/usr/bin/env python3
# =============================================================================
# AABC Accredited Birth Center Matcher for Midwives
# =============================================================================
import csv
import re

MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"

# Load Midwives
mws = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            mws[r["npi"]] = {
                "cert": r["certification_number"],
                "first": r["first_name"],
                "last": r["last_name"],
                "address": r.get("nppes_practice_address", ""),
                "city": r.get("nppes_city", ""),
                "state": r.get("nppes_state", ""),
                "zip": r.get("nppes_zip", "")
            }

# Load detailed practice addresses
with open(GEO_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        npi = r.get("npi")
        if npi in mws:
            p1 = r.get("practice_address_1", "")
            p2 = r.get("practice_address_2", "")
            mws[npi]["full_addr"] = f"{p1} {p2} {r.get('practice_city', '')} {r.get('practice_state', '')}".upper()

# Birth Center Keyword Patterns
bc_pattern = re.compile(
    r"\b(BIRTH\s*CENTER|BIRTH\s*CENTRE|BIRTHING\s*CENTER|BIRTHING\s*HOME|MIDWIFERY\s*CENTER|FAMILY\s*BIRTH|COMMUNITY\s*BIRTH|NATURAL\s*BIRTH|HOME\s*BIRTH|BIRTH\s*WORKS|BIRTH\s*SUITE|MATERNITY\s*CENTER)\b",
    re.IGNORECASE
)

matched_bc = []
for npi, mw in mws.items():
    addr_blob = mw.get("full_addr", mw.get("address", "")).upper()
    if bc_pattern.search(addr_blob):
        matched_bc.append((npi, mw["cert"], mw["first"], mw["last"], mw.get("full_addr", addr_blob)))

print("=== AABC & Freestanding Birth Center Keyword Search Results ===")
print(f"Total Cohort Midwives: {len(mws)}")
print(f"Identified Birth Center Midwives: {len(matched_bc)}\n")

print("Sample Matches:")
for m in matched_bc[:15]:
    print(f"  CNM {m[2]} {m[3]} ({m[1]}) -> Address/Facility: {m[4]}")
