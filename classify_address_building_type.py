#!/usr/bin/env python3
# =============================================================================
# Practice Address Physical Building Taxonomy Classifier
# =============================================================================
# Classifies midwife practice addresses into exact physical building categories:
# 1. Hospital Main Campus (Direct campus address match)
# 2. Medical Office Building (MOB) / Physician Pavilion (Suites, MOB, Plaza)
# 3. Freestanding Birth Center (FBC) (CABC registry / Birth Center facility)
# 4. Outpatient Community Clinic / Standalone Office
# =============================================================================

import csv
import re

MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
HOSP_FILE = "artifacts/ob_hospitals_geocoded.csv"
CABC_FILE = "artifacts/cabc_accredited_birth_centers_master.csv"
OUT_CSV = "artifacts/cohort_midwife_building_taxonomy.csv"

print("=== Practice Address Physical Building Taxonomy Classifier ===")

# 1. Load Midwives & Address Metadata
coh = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            coh[r["npi"].strip()] = {
                "cert": r["certification_number"],
                "first": r["first_name"],
                "last": r["last_name"],
                "state": r.get("nppes_state", r.get("state", ""))
            }

N_cohort = len(coh)

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

def norm(s):
    s = str(s).upper().strip()
    s = re.sub(r"\bAVENUE\b", "AVE", s)
    s = re.sub(r"\bSTREET\b", "ST", s)
    s = re.sub(r"\bROAD\b", "RD", s)
    s = re.sub(r"\bBOULEVARD\b", "BLVD", s)
    s = re.sub(r"\bDRIVE\b", "DR", s)
    s = re.sub(r"\bPARKWAY\b", "PKWY", s)
    s = re.sub(r"\bSUITE\b.*|\bSTE\b.*|#.*|\bBLDG\b.*|\bP\.O\.\s*BOX\b.*", "", s)
    return re.sub(r"[^\w\s]", "", s).strip()

# 2. Load Hospital Addresses
hosp_addrs = set()
with open(HOSP_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        addr = norm(r.get("geocode_address_1", ""))
        st = r.get("geocode_state", "").upper().strip()
        if addr and st:
            hosp_addrs.add(f"{addr}_{st}")

# 3. Load CABC Birth Center Addresses
cabc_addrs = set()
with open(CABC_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        addr = norm(r.get("full_address", ""))
        st = r.get("state", "").upper().strip()
        if addr and st:
            cabc_addrs.add(f"{addr}_{st}")

# 4. MOB Descriptors Regex
mob_regex = re.compile(
    r"\b(STE|SUITE|MOB|MEDICAL OFFICE|PROFESSIONAL BUILDING|PROFESSIONAL PLAZA|PAVILION|MEDICAL PLAZA|TOWER|SUITE|BLDG|BUILDING|FL|FLOOR|DEPT)\b",
    re.IGNORECASE
)

classified = []
counts = {
    "Hospital Main Campus": 0,
    "Medical Office Building (MOB) / Professional Pavilion": 0,
    "Freestanding Birth Center (FBC)": 0,
    "Outpatient Community Clinic / Standalone Office": 0
}

for npi, mw in coh.items():
    p1 = mw.get("addr1", "")
    p2 = mw.get("addr2", "")
    full_str = f"{p1} {p2}".strip()
    norm_p1 = norm(p1)
    st = mw.get("state", "").upper()
    key = f"{norm_p1}_{st}"
    
    # Classify Building Type.
    #
    # EXACT KEY EQUALITY ONLY. This previously also accepted
    #     any(h_k in key for h_k in hosp_addrs if len(h_k) > 10)
    # which is a SUBSTRING test, not an address match. A hospital at
    # "100 MAIN ST_NY" therefore matched a midwife at "2100 MAIN ST_NY",
    # because the hospital key is literally a substring of the midwife key.
    # Street numbers are prefixes of other street numbers constantly
    # (1/11/111 PARK AVE, 12/112 MAIN ST), so this manufactured hospital
    # affiliations that look authoritative and cannot be falsified. Same
    # failure class as the substring name matching already recorded for this
    # project. A missing match must read as "not a hospital campus", never as
    # the nearest plausible one.
    if key in hosp_addrs:
        btype = "Hospital Main Campus"
    elif key in cabc_addrs or "BIRTH CENTER" in full_str.upper() or "BIRTHING CENTER" in full_str.upper():
        btype = "Freestanding Birth Center (FBC)"
    elif bool(mob_regex.search(full_str)):
        btype = "Medical Office Building (MOB) / Professional Pavilion"
    else:
        btype = "Outpatient Community Clinic / Standalone Office"
        
    counts[btype] += 1
    classified.append({
        "certification_number": mw["cert"],
        "npi": npi,
        "first_name": mw["first"],
        "last_name": mw["last"],
        "practice_address_1": p1,
        "practice_address_2": p2,
        "practice_city": mw["city"],
        "practice_state": mw["state"],
        "building_type": btype
    })

print(f"=========================================================================")
print(f"         PRACTICE ADDRESS PHYSICAL BUILDING TAXONOMY (N = {N_cohort})     ")
print(f"=========================================================================")

for btype, count in counts.items():
    pct = count / N_cohort * 100
    print(f"  - {btype}: {count:,} midwives ({pct:.2f}%)")

# Save output
with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if classified:
        writer = csv.DictWriter(f, fieldnames=list(classified[0].keys()))
        writer.writeheader()
        writer.writerows(classified)

print(f"\nSaved building taxonomy dataset to: {OUT_CSV}")

print("\nSample Building Classifications:")
for c in classified[:15]:
    print(f"  CNM {c['first_name']} {c['last_name']} ({c['practice_city']}, {c['practice_state']}) -> {c['practice_address_1']} {c['practice_address_2']} [{c['building_type']}]")
