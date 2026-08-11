#!/usr/bin/env python3
# =============================================================================
# Precision CABC Birth Center Directory Parser & Midwife Cohort Matcher
# =============================================================================
import re
import csv

HTML_FILE = "/Users/tmuffly/.gemini/antigravity/brain/8b54cf89-ea59-406d-b675-3b5a984f2732/.system_generated/steps/883/content.md"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
OUT_MASTER = "artifacts/cabc_birth_centers_master_clean.csv"
OUT_MATCHES = "artifacts/cabc_matched_midwives_final.csv"

print("=== Precision CABC Birth Center Parser & Matcher ===")

with open(HTML_FILE, "r", encoding="utf-8", errors="ignore") as f:
    html_text = f.read()

# Pattern to capture Name, Address lines, Phone
# Format in file:
#   Name
#   Address:
#   Street
#   City, State Zip
#   Phone: ...
pattern = re.compile(
    r"([A-Za-z0-9\s\,\&\.\-\'\(\)]+?)\s+Address:\s*\n([^\n]+)\s*\n?([^\n]*?)\s*(?:Phone:|\nPhone:)",
    re.MULTILINE
)

matches = pattern.findall(html_text)
print(f"Found {len(matches)} potential raw CABC birth center blocks.")

birth_centers = []
for m in matches:
    name = m[0].strip()
    addr1 = m[1].strip()
    addr2 = m[2].strip()
    
    # Filter header noise
    if "Browse" in name or "Search" in name or len(name) < 3:
        continue
        
    full_addr = f"{addr1} {addr2}".strip()
    
    # Extract City, State, ZIP
    zip_m = re.search(r"\b(\d{5})\b", full_addr)
    zip_code = zip_m.group(1) if zip_m else ""
    
    state_m = re.search(r"\b([A-Z]{2})\b\s*\d{5}", full_addr)
    state = state_m.group(1) if state_m else ""
    
    # Extract city (precedes state in address)
    city_m = re.search(r"([A-Za-z\s]+),\s*([A-Z]{2})", full_addr)
    city = city_m.group(1).strip() if city_m else ""
    
    birth_centers.append({
        "bc_id": f"CABC_{len(birth_centers)+1:03d}",
        "facility_name": name,
        "street_address": addr1,
        "full_address": full_addr,
        "city": city,
        "state": state,
        "zip_code": zip_code
    })

print(f"Successfully Extracted {len(birth_centers)} Verified CABC Accredited Birth Centers!")

# Save Master CABC Birth Center File
with open(OUT_MASTER, "w", newline="", encoding="utf-8") as f:
    if birth_centers:
        writer = csv.DictWriter(f, fieldnames=list(birth_centers[0].keys()))
        writer.writeheader()
        writer.writerows(birth_centers)

print(f"Saved CABC Master Directory to: {OUT_MASTER}\n")

print("Sample CABC Accredited Birth Centers:")
for bc in birth_centers[:10]:
    print(f"  [{bc['bc_id']}] {bc['facility_name']} | {bc['street_address']} | {bc['city']}, {bc['state']} {bc['zip_code']}")

# Load active cohort midwives
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
    s = re.sub(r"\bSUITE\b.*|\bSTE\b.*|#.*|\bBLDG\b.*", "", s)
    return re.sub(r"[^\w\s]", "", s).strip()

matched_midwives = []
for npi, mw in coh.items():
    mw_addr_norm = norm(mw.get("addr1", mw["nppes_addr"]))
    mw_zip = mw.get("zip", "")[:5]
    mw_city = norm(mw.get("city", ""))
    mw_state = mw.get("state", "").upper()
    
    for bc in birth_centers:
        bc_addr_norm = norm(bc["street_address"])
        bc_zip = bc["zip_code"]
        bc_state = bc["state"]
        
        # Match Tier 1: Exact Normalized Street Address Match + State
        street_hit = mw_addr_norm and bc_addr_norm and (mw_addr_norm in bc_addr_norm or bc_addr_norm in mw_addr_norm)
        zip_hit = mw_zip and bc_zip and mw_zip == bc_zip
        state_hit = mw_state and bc_state and mw_state == bc_state
        
        if (street_hit and state_hit) or (zip_hit and norm(bc["facility_name"]) in norm(mw.get("addr1", ""))):
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
print(f"  VERIFIED CABC BIRTH CENTER MIDWIFE MATCHES: {len(matched_midwives)} midwives")
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
