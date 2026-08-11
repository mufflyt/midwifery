#!/usr/bin/env python3
# =============================================================================
# Full-Cohort Open Payments to NPPES Type 2 Organization Cross-Referencer
# =============================================================================
import requests
import csv
import json
import time
import re
import concurrent.futures

OP_PROFILE_CSV = "data/CMS_Open_Payments_Profile_Supplement.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
OUT_CSV = "artifacts/cohort_midwives_open_payments_type2_organizations_full.csv"

print("=== Full-Cohort Open Payments to Type 2 Organization Cross-Referencer ===")

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
print(f"Loaded {N_cohort} active cohort midwives.")

# 2. Extract Open Payments Addresses
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
                op_addrs[npi] = {
                    "addr1": addr1,
                    "city": city,
                    "state": state,
                    "zip": zip_code
                }

print(f"Extracted Open Payments addresses for {len(op_addrs)} cohort midwives.")

# Function to query single midwife address
nppes_api_url = "https://npiregistry.cms.hhs.gov/api/"

def fetch_type2_org(item):
    npi, op = item
    mw = coh_npis[npi]
    params = {
        "version": "2.1",
        "enumeration_type": "NPI-2",
        "address_purpose": "LOCATION",
        "city": op["city"],
        "state": op["state"],
        "postal_code": op["zip"],
        "limit": 10
    }
    
    try:
        r = requests.get(nppes_api_url, params=params, timeout=8)
        if r.status_code == 200:
            data = r.json()
            results = data.get("results", [])
            op_addr_clean = re.sub(r"[^\w\s]", "", op["addr1"].upper())
            
            for res in results:
                org_npi = res.get("number")
                basic = res.get("basic", {})
                org_name = basic.get("organization_name", basic.get("name", ""))
                addresses = res.get("addresses", [])
                taxonomies = res.get("taxonomies", [])
                tax_desc = ", ".join([t.get("desc", "") for t in taxonomies if t.get("desc")])
                
                for a in addresses:
                    a1 = re.sub(r"[^\w\s]", "", a.get("address_1", "").upper())
                    if op_addr_clean[:8] in a1 or a1[:8] in op_addr_clean:
                        return {
                            "certification_number": mw["cert"],
                            "midwife_npi": npi,
                            "first_name": mw["first"],
                            "last_name": mw["last"],
                            "open_payments_address": f"{op['addr1']}, {op['city']}, {op['state']} {op['zip']}",
                            "type2_organization_name": org_name,
                            "type2_organization_npi": org_npi,
                            "organization_taxonomy": tax_desc
                        }
    except Exception:
        pass
    return None

print("\nExecuting multi-threaded NPPES Type 2 Organization address resolution...")

matched_orgs = []
items = list(op_addrs.items())

with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
    results = executor.map(fetch_type2_org, items)
    for res in results:
        if res:
            matched_orgs.append(res)

print(f"\n=========================================================")
print(f"  TYPE 2 ORGANIZATIONS MATCHED ACROSS COHORT: {len(matched_orgs)} midwives")
print(f"  PERCENTAGE OF OPEN PAYMENTS COHORT RESOLVED: {len(matched_orgs)/len(op_addrs)*100:.2f}%")
print(f"=========================================================")

# Save output
with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if matched_orgs:
        writer = csv.DictWriter(f, fieldnames=list(matched_orgs[0].keys()))
        writer.writeheader()
        writer.writerows(matched_orgs)

print(f"Saved full Type 2 Organization matches to: {OUT_CSV}")
