#!/usr/bin/env python3
# =============================================================================
# Precision CABC Accredited Birth Center Master Parser & Cohort Matcher
# =============================================================================
import os
import re
import csv
import sys

# The CABC accredited-centre directory renders its listings client-side, so the
# input is a SAVED SNAPSHOT of the rendered page rather than a fetch. That
# snapshot is not in the repo, and the path this script used to carry pointed
# into a scratch directory on an account that does not exist on this machine
# (/Users/tmuffly/...), so the script has not been runnable as committed. It is
# kept because it documents how the two tracked artifacts were produced.
#
# To re-run: save the rendered directory page to the path below. Re-parsing a
# fresh capture will NOT reproduce the tracked artifacts byte for byte -- CABC
# accreditation is a moving roster, and that is a real change in the source,
# not a bug in this parser.
HTML_FILE = os.environ.get("CABC_SNAPSHOT", "data/cabc_directory_snapshot.html")
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
OUT_BC_MASTER = "artifacts/cabc_accredited_birth_centers_master.csv"
OUT_MATCHES = "artifacts/cabc_matched_midwives_final.csv"

print("=== Precision CABC Accredited Birth Center Master Extractor ===")

# Fail with the reason and the remedy. Reading a missing snapshot used to raise
# a bare FileNotFoundError naming someone else's home directory, which reads as
# a broken machine rather than a missing input.
if not os.path.exists(HTML_FILE):
    sys.exit(
        f"CABC snapshot not found at {HTML_FILE}.\n"
        "Save the rendered CABC accredited-centre directory page there, or set\n"
        "CABC_SNAPSHOT to its location. The two artifacts this script writes\n"
        "(artifacts/cabc_accredited_birth_centers_master.csv and\n"
        "artifacts/cabc_matched_midwives_final.csv) are already committed."
    )

with open(HTML_FILE, "r", encoding="utf-8", errors="ignore") as f:
    text = f.read()

# Pattern for CABC Item Card
# Title: <div class="element element_...  title ">\s*(.*?)\s*</div>
# Address: <strong>Address</strong>:<br />\s*(.*?)\s*</div>
card_pattern = re.compile(
    r'title\s*">\s*(.*?)\s*</div>.*?<strong>Address</strong>:<br />\s*(.*?)\s*</div>',
    re.DOTALL | re.IGNORECASE
)

matches = card_pattern.findall(text)
print(f"Total CABC Birth Center HTML Cards Found: {len(matches)}")

birth_centers = []
for name_raw, addr_raw in matches:
    name = re.sub(r"\s+", " ", name_raw).strip()
    # Replace <br /> with newline/comma
    addr_clean = re.sub(r"<br\s*/?>", ", ", addr_raw)
    addr_clean = re.sub(r"<[^>]+>", "", addr_clean).strip()
    addr_clean = re.sub(r"\s+", " ", addr_clean)
    
    # Extract City, State, ZIP
    zip_m = re.search(r"\b(\d{5}(?:-\d{4})?)\b", addr_clean)
    zip_code = zip_m.group(1)[:5] if zip_m else ""
    
    state_m = re.search(r"\b([A-Z]{2})\b\s*\d{5}", addr_clean)
    state = state_m.group(1) if state_m else ""
    
    city_m = re.search(r"([A-Za-z\s]+),\s*([A-Z]{2})\s*\d{5}", addr_clean)
    city = city_m.group(1).strip() if city_m else ""
    
    # Avoid duplicates
    key = f"{name.upper()}_{zip_code}"
    if not any(bc.get("key") == key for bc in birth_centers):
        birth_centers.append({
            "key": key,
            "bc_id": f"CABC_{len(birth_centers)+1:03d}",
            "facility_name": name,
            "full_address": addr_clean,
            "city": city,
            "state": state,
            "zip_code": zip_code
        })

print(f"Successfully Parsed {len(birth_centers)} Unique CABC Accredited Freestanding Birth Centers!")

# Save Master CABC Directory
with open(OUT_BC_MASTER, "w", newline="", encoding="utf-8") as f:
    if birth_centers:
        writer = csv.DictWriter(f, fieldnames=[k for k in birth_centers[0].keys() if k != "key"])
        writer.writeheader()
        for bc in birth_centers:
            row = {k: v for k, v in bc.items() if k != "key"}
            writer.writerow(row)

print(f"Saved CABC Master Directory to: {OUT_BC_MASTER}\n")

print("Sample CABC Accredited Birth Centers:")
for bc in birth_centers[:12]:
    print(f"  [{bc['bc_id']}] {bc['facility_name']} | {bc['full_address']}")

# 2. Load Cohort Midwives
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

matched_midwives = []
for npi, mw in coh.items():
    mw_addr_norm = norm(mw.get("addr1", mw["nppes_addr"]))
    mw_zip = mw.get("zip", "")[:5]
    mw_city = norm(mw.get("city", ""))
    mw_state = mw.get("state", "").upper()
    
    # Extract street number
    mw_num_match = re.search(r"\b\d+\b", mw_addr_norm)
    mw_num = mw_num_match.group(0) if mw_num_match else ""
    
    for bc in birth_centers:
        bc_addr_norm = norm(bc["full_address"])
        bc_zip = bc["zip_code"]
        bc_state = bc["state"]
        
        bc_num_match = re.search(r"\b\d+\b", bc_addr_norm)
        bc_num = bc_num_match.group(0) if bc_num_match else ""
        
        # Matching Rules:
        # Rule 1: Exact ZIP + Street Number Match
        r1 = mw_zip and bc_zip and mw_zip == bc_zip and mw_num and bc_num and mw_num == bc_num
        # Rule 2: State Match + Street Number Match + Substring Street Address
        r2 = mw_state and bc_state and mw_state == bc_state and mw_num and bc_num and mw_num == bc_num and (mw_addr_norm in bc_addr_norm or bc_addr_norm in mw_addr_norm)
        # Rule 3: Exact Facility Name in Midwife Address
        r3 = norm(bc["facility_name"]) in norm(mw.get("addr1", "")) or norm(bc["facility_name"]) in norm(mw.get("nppes_addr", ""))
        
        if r1 or r2 or r3:
            matched_midwives.append({
                "certification_number": mw["cert"],
                "npi": npi,
                "first_name": mw["first"],
                "last_name": mw["last"],
                "midwife_city": mw["city"],
                "midwife_state": mw["state"],
                "practice_address": mw.get("addr1", mw["nppes_addr"]),
                "matched_cabc_birth_center": bc["facility_name"],
                "cabc_address": bc["full_address"],
                "cabc_zip": bc["zip_code"]
            })
            break

print(f"\n=========================================================================")
print(f"  VERIFIED CABC ACCREDITED BIRTH CENTER MIDWIFE MATCHES: {len(matched_midwives)} midwives")
print(f"  UNIQUE CABC ACCREDITED BIRTH CENTERS COVERED: {len(set(m['matched_cabc_birth_center'] for m in matched_midwives))}")
print(f"=========================================================================")

# Save output
with open(OUT_MATCHES, "w", newline="", encoding="utf-8") as f:
    if matched_midwives:
        writer = csv.DictWriter(f, fieldnames=list(matched_midwives[0].keys()))
        writer.writeheader()
        writer.writerows(matched_midwives)

print(f"\nSaved CABC matched midwives to: {OUT_MATCHES}")

print("\nSample Verified CABC Birth Center Midwives:")
for rec in matched_midwives[:15]:
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['midwife_city']}, {rec['midwife_state']}) -> {rec['matched_cabc_birth_center']} [{rec['cabc_address']}]")
