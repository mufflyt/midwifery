#!/usr/bin/env python3
# =============================================================================
# High-Precision postmastr Address Match Yield Calculator
# =============================================================================
import csv
import re
import os

OP_PROFILE_CSV = "data/CMS_Open_Payments_Profile_Supplement.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
HOSP_FILE = "data/CMS_Hospital_General_Information.csv"
CABC_FILE = "artifacts/cabc_accredited_birth_centers_master.csv"
TYPE2_FILE = "artifacts/cohort_midwives_open_payments_type2_organizations_full.csv"
OUT_CSV = "artifacts/cohort_midwives_open_payments_postmastr_final_yield.csv"

print("=== High-Precision postmastr Address Match Yield Calculator ===")

# 1. Load Active Cohort Midwives
coh_npis = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            coh_npis[r["npi"].strip()] = {
                "cert": r["certification_number"],
                "first": r["first_name"],
                "last": r["last_name"],
                "state": r.get("nppes_state", r.get("state", ""))
            }

N_cohort = len(coh_npis)

# 2. postmastr / USPS Address Standardizer
USPS_ABBR = {
    r"\bAVENUE\b": "AVE", r"\bSTREET\b": "ST", r"\bROAD\b": "RD",
    r"\bBOULEVARD\b": "BLVD", r"\bDRIVE\b": "DR", r"\bPARKWAY\b": "PKWY",
    r"\bLANE\b": "LN", r"\bCOURT\b": "CT", r"\bCIRCLE\b": "CIR",
    r"\bHIGHWAY\b": "HWY", r"\bNORTH\b": "N", r"\bSOUTH\b": "S",
    r"\bEAST\b": "E", r"\bWEST\b": "W", r"\bNORTHEAST\b": "NE",
    r"\bNORTHWEST\b": "NW", r"\bSOUTHEAST\b": "SE", r"\bSOUTHWEST\b": "SW",
    r"\bSUITE\b.*|\bSTE\b.*|#.*|\bBLDG\b.*|\bBUILDING\b.*|\bFL\b.*|\bFLOOR\b.*|\bP\.O\.\s*BOX\b.*": ""
}

def standardize_usps_address(addr_str):
    if not addr_str:
        return ""
    s = str(addr_str).upper().strip()
    for pat, rep in USPS_ABBR.items():
        s = re.sub(pat, rep, s)
    s = re.sub(r"[^\w\s]", "", s)
    return re.sub(r"\s+", " ", s).strip()

# 3. Load Open Payments Addresses
op_addrs = {}
with open(OP_PROFILE_CSV, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        npi = r.get("Covered_Recipient_NPI", "").strip()
        if npi in coh_npis and npi not in op_addrs:
            addr1 = r.get("Covered_Recipient_Profile_Address_Line_1", "").strip()
            city = r.get("Covered_Recipient_Profile_City", "").strip()
            state = r.get("Covered_Recipient_Profile_State", "").strip()
            zip_code = r.get("Covered_Recipient_Profile_Zipcode", "").strip()[:5]
            if addr1 and city and state:
                std_street = standardize_usps_address(addr1)
                op_addrs[npi] = {
                    "raw_addr": addr1,
                    "std_street": std_street,
                    "city": city,
                    "state": state,
                    "zip": zip_code
                }

N_op = len(op_addrs)

# 4. Load Master Hospital Addresses
hosp_addrs = {}
if os.path.exists(HOSP_FILE):
    with open(HOSP_FILE, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        for r in reader:
            std = standardize_usps_address(r.get("Address", ""))
            st = r.get("State", "").upper().strip()
            name = r.get("Facility Name", "").strip()
            ccn = r.get("Facility ID", "").strip()
            if std and st and name:
                key = f"{std}_{st}"
                hosp_addrs[key] = {"facility_name": name, "facility_id": ccn, "type": "Hospital Main Campus"}

# 5. Load CABC Birth Center Addresses
cabc_addrs = {}
if os.path.exists(CABC_FILE):
    with open(CABC_FILE, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        for r in reader:
            std = standardize_usps_address(r.get("full_address", ""))
            st = r.get("state", "").upper().strip()
            name = r.get("facility_name", "").strip()
            if std and st and name:
                key = f"{std}_{st}"
                cabc_addrs[key] = {"facility_name": name, "facility_id": r.get("bc_id", ""), "type": "Accredited Birth Center"}

# 6. Load Type 2 Organization NPI Matches
type2_matches = {}
if os.path.exists(TYPE2_FILE):
    with open(TYPE2_FILE, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        for r in reader:
            npi = r.get("midwife_npi", "").strip()
            if npi:
                type2_matches[npi] = {
                    "facility_name": r.get("type2_organization_name", "").strip(),
                    "facility_id": r.get("type2_organization_npi", "").strip(),
                    "type": "NPPES Type 2 Organization NPI"
                }

# Match Engine
matched_final = []
for npi, op in op_addrs.items():
    mw = coh_npis[npi]
    key = f"{op['std_street']}_{op['state']}"
    
    match = None
    if npi in type2_matches:
        match = type2_matches[npi]
    elif key in hosp_addrs:
        match = hosp_addrs[key]
    elif key in cabc_addrs:
        match = cabc_addrs[key]
    else:
        # Check street number matching against hospital master
        op_num_match = re.search(r"\b\d+\b", op["std_street"])
        op_num = op_num_match.group(0) if op_num_match else ""
        if op_num:
            for h_key, h_info in hosp_addrs.items():
                if h_key.endswith(f"_{op['state']}"):
                    h_street = h_key.rsplit("_", 1)[0]
                    h_num_match = re.search(r"\b\d+\b", h_street)
                    h_num = h_num_match.group(0) if h_num_match else ""
                    if op_num == h_num and (op["std_street"] in h_street or h_street in op["std_street"]):
                        match = h_info
                        break
                        
    if match:
        matched_final.append({
            "certification_number": mw["cert"],
            "midwife_npi": npi,
            "first_name": mw["first"],
            "last_name": mw["last"],
            "open_payments_address": f"{op['raw_addr']}, {op['city']}, {op['state']} {op['zip']}",
            "matched_facility_name": match["facility_name"],
            "matched_facility_id": match["facility_id"],
            "facility_linkage_type": match["type"]
        })

print(f"=========================================================================")
print(f"       POSTMASTR STANDARDIZED MATCH YIELD SUMMARY                        ")
print(f"=========================================================================")
print(f"  - TOTAL OPEN PAYMENTS MIDWIVES:              {N_op:,}")
print(f"  - RESOLVED FACILITY & TYPE 2 MATCHES:        {len(matched_final):,}")
print(f"  - MATCH YIELD OF OPEN PAYMENTS COHORT:       {len(matched_final)/N_op*100:.2f}%")
print(f"  - PERCENTAGE OF FULL ACTIVE COHORT (11,920): {len(matched_final)/N_cohort*100:.2f}%")
print(f"=========================================================================")

# Save output
with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if matched_final:
        writer = csv.DictWriter(f, fieldnames=list(matched_final[0].keys()))
        writer.writeheader()
        writer.writerows(matched_final)

print(f"\nSaved final postmastr match yield dataset to: {OUT_CSV}")

print("\nSample Resolved Facility Matches:")
for m in matched_final[:15]:
    print(f"  CNM {m['first_name']} {m['last_name']} ({m['open_payments_address']}) -> Matched Facility: {m['matched_facility_name']} [{m['facility_linkage_type']}]")
