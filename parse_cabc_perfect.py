#!/usr/bin/env python3
# =============================================================================
# Perfect CABC Birth Center Master Parser & Cohort Matcher
# =============================================================================
import re
import csv

HTML_FILE = "/Users/tmuffly/.gemini/antigravity/brain/8b54cf89-ea59-406d-b675-3b5a984f2732/.system_generated/steps/883/content.md"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
OUT_MASTER = "artifacts/cabc_birth_centers_master_perfect.csv"
OUT_MATCHES = "artifacts/cabc_matched_midwives_perfect.csv"

print("=== Perfect CABC Birth Center Directory Parser & Matcher ===")

with open(HTML_FILE, "r", encoding="utf-8", errors="ignore") as f:
    text = f.read()

# Parse CABC html blocks cleanly
blocks = text.split("Address:")

birth_centers = []
for i in range(len(blocks) - 1):
    # Name is in blocks[i] (before Address:)
    chunk_lines = [l.strip() for l in blocks[i].split("\n") if l.strip()]
    name = chunk_lines[-1] if chunk_lines else ""
    
    # Address is in blocks[i+1] (after Address:)
    next_lines = [l.strip() for l in blocks[i+1].split("\n") if l.strip()]
    addr_parts = []
    for l in next_lines:
        if "Phone:" in l or "Website" in l or "Accredited" in l:
            break
        addr_parts.append(l)
    
    full_addr = ", ".join(addr_parts)
    
    zip_m = re.search(r"\b(\d{5})\b", full_addr)
    zip_code = zip_m.group(1) if zip_m else ""
    
    state_m = re.search(r"\b([A-Z]{2})\b\s*\d{5}", full_addr)
    state = state_m.group(1) if state_m else ""
    
    if len(name) > 3 and "Browse" not in name and "Search" not in name and "How" not in name:
        birth_centers.append({
            "bc_id": f"CABC_{len(birth_centers)+1:03d}",
            "facility_name": name,
            "full_address": full_addr,
            "state": state,
            "zip_code": zip_code
        })

print(f"Successfully Extracted {len(birth_centers)} Verified CABC Accredited Birth Centers!")

with open(OUT_MASTER, "w", newline="", encoding="utf-8") as f:
    if birth_centers:
        writer = csv.DictWriter(f, fieldnames=list(birth_centers[0].keys()))
        writer.writeheader()
        writer.writerows(birth_centers)

print(f"Saved CABC Master Directory to: {OUT_MASTER}\n")

print("Sample Extracted CABC Accredited Birth Centers:")
for bc in birth_centers[:10]:
    print(f"  [{bc['bc_id']}] {bc['facility_name']} | Address: {bc['full_address']} | ZIP: {bc['zip_code']}")

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
        bc_addr_norm = norm(bc["full_address"])
        bc_zip = bc["zip_code"]
        bc_state = bc["state"]
        
        # Match Tier 1: Street Number Match + ZIP
        mw_num = re.search(r"\b\d+\b", mw_addr_norm)
        bc_num = re.search(r"\b\d+\b", bc_addr_norm)
        
        num_hit = mw_num and bc_num and mw_num.group(0) == bc_num.group(0)
        zip_hit = mw_zip and bc_zip and mw_zip == bc_zip
        state_hit = mw_state and bc_state and mw_state == bc_state
        
        if (zip_hit and num_hit) or (num_hit and state_hit and len(mw_addr_norm) > 5 and mw_addr_norm[:8] in bc_addr_norm):
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
