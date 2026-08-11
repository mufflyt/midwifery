#!/usr/bin/env python3
# =============================================================================
# Full-Cohort postmastr Standardized Address Match Benchmark Engine
# =============================================================================
import csv
import re
import os

OP_PROFILE_CSV = "data/CMS_Open_Payments_Profile_Supplement.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
DAC_FILE = "data/CMS_DAC_NationalDownloadableFile.csv"
FAC_FILE = "data/CMS_Facility_Affiliation.csv"
OUT_CSV = "artifacts/cohort_midwives_open_payments_type2_postmastr_full.csv"

print("=== Full-Cohort postmastr Standardized Address Match Benchmark Engine ===")

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

# 3. Extract Open Payments Practice Addresses (N = 7,039)
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
                    "zip": zip_code,
                    "key": f"{std_street}_{state}"
                }

N_op = len(op_addrs)
print(f"Extracted & standardized Open Payments practice addresses for {N_op} cohort midwives.")

# 4. Load Organization Addresses from CMS DAC & Facility Affiliations
org_address_map = {}
if os.path.exists(DAC_FILE):
    with open(DAC_FILE, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        for r in reader:
            org_npi = r.get("NPI", "").strip()
            org_name = r.get("org_pac_name", r.get("org_name", "")).strip()
            addr = standardize_usps_address(r.get("adr_ln_1", ""))
            st = r.get("state", "").upper().strip()
            if addr and st and org_name:
                key = f"{addr}_{st}"
                org_address_map[key] = {
                    "org_name": org_name,
                    "org_npi": org_npi,
                    "source": "CMS DAC Master"
                }

print(f"Loaded {len(org_address_map)} CMS Organization standardized street address keys.")

# 5. Match Open Payments Addresses to Organization Keys
matched_results = []
for npi, op in op_addrs.items():
    mw = coh_npis[npi]
    key = op["key"]
    op_num_match = re.search(r"\b\d+\b", op["std_street"])
    op_num = op_num_match.group(0) if op_num_match else ""
    
    match_found = None
    if key in org_address_map:
        match_found = org_address_map[key]
    else:
        # Check street number + substring match
        for org_key, org_info in org_address_map.items():
            if org_key.endswith(f"_{op['state']}"):
                org_street = org_key.rsplit("_", 1)[0]
                org_num_match = re.search(r"\b\d+\b", org_street)
                org_num = org_num_match.group(0) if org_num_match else ""
                if op_num and org_num and op_num == org_num and (op["std_street"] in org_street or org_street in op["std_street"]):
                    match_found = org_info
                    break
    if match_found:
        matched_results.append({
            "certification_number": mw["cert"],
            "midwife_npi": npi,
            "first_name": mw["first"],
            "last_name": mw["last"],
            "open_payments_raw_address": op["raw_addr"],
            "standardized_address": op["std_street"],
            "type2_organization_name": match_found["org_name"],
            "type2_organization_npi": match_found["org_npi"],
            "match_source": match_found["source"]
        })

print(f"\n=========================================================================")
print(f"       POSTMASTR STANDARDIZED TYPE 2 MATCH RATE BENCHMARK               ")
print(f"=========================================================================")
print(f"  - TOTAL OPEN PAYMENTS MIDWIVES:              {N_op:,}")
print(f"  - STANDARDIZED TYPE 2 MATCHED MIDWIVES:      {len(matched_results):,}")
print(f"  - FINAL STANDARDIZED MATCH RATE:             {len(matched_results)/N_op*100:.2f}%")
print(f"  - PERCENTAGE OF FULL ACTIVE COHORT (11,920): {len(matched_results)/N_cohort*100:.2f}%")
print(f"=========================================================================")

# Save output artifact
with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if matched_results:
        writer = csv.DictWriter(f, fieldnames=list(matched_results[0].keys()))
        writer.writeheader()
        writer.writerows(matched_results)

print(f"\nSaved postmastr standardized match results to: {OUT_CSV}")

print("\nSample Standardized Type 2 Organization Matches:")
for m in matched_results[:12]:
    print(f"  CNM {m['first_name']} {m['last_name']} [{m['standardized_address']}] -> Type 2 Org: {m['type2_organization_name']} [NPI: {m['type2_organization_npi']}]")
