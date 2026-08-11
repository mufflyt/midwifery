#!/usr/bin/env python3
# =============================================================================
# CABC Accredited Freestanding Birth Center Parser & Midwife Cohort Matcher
# =============================================================================
import re
import csv
import os

HTML_CONTENT_FILE = "/Users/tmuffly/.gemini/antigravity/brain/8b54cf89-ea59-406d-b675-3b5a984f2732/.system_generated/steps/883/content.md"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
OUT_BC_MASTER = "artifacts/cabc_accredited_birth_centers_master.csv"
OUT_MATCHES = "artifacts/cohort_midwives_matched_to_cabc_birth_centers.csv"

print("=== CABC Accredited Birth Center Master Parser & Matcher ===")

# 1. Parse CABC Birth Centers from HTML content
with open(HTML_CONTENT_FILE, "r", encoding="utf-8", errors="ignore") as f:
    text = f.read()

# Pattern for birth center entries in the CABC page
pattern = re.compile(
    r"([A-Za-z0-9\s\,\&\.\-\'\(\)]+?)\s+Address:\s*\n?([^\n]+)\s*\n?([^\n]*?)\s*(?:Phone:|\nPhone:)",
    re.MULTILINE
)

raw_blocks = text.split("Address:")
print(f"Total Raw CABC Address Blocks Found: {len(raw_blocks) - 1}")

birth_centers = []
for i in range(1, len(raw_blocks)):
    prev_text = raw_blocks[i-1].strip().split("\n")
    name = prev_text[-1].strip() if prev_text else "Unknown Birth Center"
    # clean name
    name = re.sub(r"^[^\w]+|[^\w]+$", "", name).strip()
    
    curr_text = raw_blocks[i].strip().split("\n")
    addr_lines = []
    phone = ""
    site = ""
    
    for line in curr_text:
        line_s = line.strip()
        if "Phone:" in line_s:
            phone = line_s.replace("Phone:", "").strip()
            break
        elif line_s and not line_s.startswith("Website") and not line_s.startswith("Accredited"):
            addr_lines.append(line_s)
            
    full_addr = ", ".join(addr_lines)
    
    # Extract ZIP, State, City
    zip_match = re.search(r"\b(\d{5}(?:-\d{4})?)\b", full_addr)
    zip_code = zip_match.group(1)[:5] if zip_match else ""
    
    state_match = re.search(r"\b([A-Z]{2})\b\s*\d{5}", full_addr)
    state = state_match.group(1) if state_match else ""
    
    if len(name) > 3 and not name.startswith("Browse"):
        birth_centers.append({
            "bc_id": f"BC_{len(birth_centers)+1:03d}",
            "facility_name": name,
            "full_address": full_addr,
            "city": addr_lines[-1].split(",")[0] if addr_lines else "",
            "state": state,
            "zip_code": zip_code,
            "phone": phone
        })

print(f"Successfully Parsed {len(birth_centers)} CABC Accredited Freestanding Birth Centers!")

# Save CABC Master Directory
with open(OUT_BC_MASTER, "w", newline="", encoding="utf-8") as f:
    if birth_centers:
        writer = csv.DictWriter(f, fieldnames=list(birth_centers[0].keys()))
        writer.writeheader()
        writer.writerows(birth_centers)

print(f"Saved CABC Master Directory to: {OUT_BC_MASTER}")

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

def norm_str(s):
    s = str(s).upper().strip()
    s = re.sub(r"\bAVENUE\b", "AVE", s)
    s = re.sub(r"\bSTREET\b", "ST", s)
    s = re.sub(r"\bROAD\b", "RD", s)
    s = re.sub(r"\bBOULEVARD\b", "BLVD", s)
    s = re.sub(r"\bDRIVE\b", "DR", s)
    s = re.sub(r"\bPARKWAY\b", "PKWY", s)
    s = re.sub(r"\bSUITE\b.*|\bSTE\b.*|#.*|\bBLDG\b.*|\bSUITE\b.*", "", s)
    return re.sub(r"[^\w\s]", "", s).strip()

# 3. Match Cohort Midwives against CABC Birth Center Master
matched_mw_bc = []
for npi, mw in coh.items():
    mw_addr1 = norm_str(mw.get("addr1", mw["nppes_addr"]))
    mw_zip = mw.get("zip", "")[:5]
    mw_city = norm_str(mw.get("city", ""))
    mw_state = mw.get("state", "").upper()
    
    for bc in birth_centers:
        bc_addr1 = norm_str(bc["full_address"])
        bc_zip = bc["zip_code"]
        bc_state = bc["state"]
        
        # Match Tier A: Exact Normalized Street Address + ZIP / City Match
        addr_match = mw_addr1 and (mw_addr1 in bc_addr1 or bc_addr1 in mw_addr1)
        zip_match = mw_zip and bc_zip and mw_zip == bc_zip
        state_match = mw_state and bc_state and mw_state == bc_state
        
        if (addr_match and (zip_match or state_match)) or (zip_match and norm_str(bc["facility_name"]) in norm_str(mw.get("addr1", ""))):
            matched_mw_bc.append({
                "certification_number": mw["cert"],
                "npi": npi,
                "first_name": mw["first"],
                "last_name": mw["last"],
                "midwife_city": mw["city"],
                "midwife_state": mw["state"],
                "midwife_address": mw.get("addr1", mw["nppes_addr"]),
                "matched_birth_center_name": bc["facility_name"],
                "birth_center_address": bc["full_address"],
                "birth_center_zip": bc["zip_code"],
                "match_confidence": "High (CABC Address Match)"
            })
            break

print(f"\n=======================================================")
print(f"  CABC MATCHED MIDWIVES: {len(matched_mw_bc)} midwives")
print(f"  UNIQUE CABC BIRTH CENTERS LINKED: {len(set(r['matched_birth_center_name'] for r in matched_mw_bc))}")
print(f"=======================================================")

# Save output
with open(OUT_MATCHES, "w", newline="", encoding="utf-8") as f:
    if matched_mw_bc:
        writer = csv.DictWriter(f, fieldnames=list(matched_mw_bc[0].keys()))
        writer.writeheader()
        writer.writerows(matched_mw_bc)

print(f"\nSaved CABC matched midwives to: {OUT_MATCHES}")

print("\nSample CABC Matched Midwives:")
for rec in matched_mw_bc[:15]:
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['midwife_city']}, {rec['midwife_state']}) -> {rec['matched_birth_center_name']} [{rec['birth_center_address']}]")
