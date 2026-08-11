#!/usr/bin/env python3
# =============================================================================
# Open Payments Address to NPPES Type 2 Organization NPI Cross-Referencer
# =============================================================================
import requests
import csv
import json
import time
import re

OP_PROFILE_CSV = "data/CMS_Open_Payments_Profile_Supplement.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
OUT_CSV = "artifacts/cohort_midwives_open_payments_type2_organizations.csv"

print("=== Open Payments Address to NPPES Type 2 Organization Cross-Referencer ===")

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

# 2. Extract Open Payments Addresses for Cohort Midwives
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

# 3. Query NPPES Registry API for Type 2 (Organization) NPIs at these exact addresses
# API Endpoint: https://npiregistry.cms.hhs.gov/api/?version=2.1&enumeration_type=NPI-2&address_purpose=LOCATION&city=...&state=...
nppes_api_url = "https://npiregistry.cms.hhs.gov/api/"

matched_orgs = []
api_query_count = 0
max_queries = 200  # Sample batch for immediate execution

print(f"\nQuerying NPPES API for Type 2 Organizations matching Open Payments practice addresses...")

for npi, op in list(op_addrs.items())[:max_queries]:
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
        r = requests.get(nppes_api_url, params=params, timeout=10)
        api_query_count += 1
        if r.status_code == 200:
            data = r.json()
            results = data.get("results", [])
            
            # Find Organization matching street address
            matched_org_name = None
            matched_org_npi = None
            matched_org_tax = None
            
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
                        matched_org_name = org_name
                        matched_org_npi = org_npi
                        matched_org_tax = tax_desc
                        break
                if matched_org_name:
                    break
            
            if matched_org_name:
                matched_orgs.append({
                    "certification_number": mw["cert"],
                    "midwife_npi": npi,
                    "first_name": mw["first"],
                    "last_name": mw["last"],
                    "open_payments_address": f"{op['addr1']}, {op['city']}, {op['state']} {op['zip']}",
                    "type2_organization_name": matched_org_name,
                    "type2_organization_npi": matched_org_npi,
                    "organization_taxonomy": matched_org_tax
                })
        time.sleep(0.1) # polite delay
    except Exception as e:
        continue

print(f"\n=========================================================")
print(f"  TYPE 2 ORGANIZATIONS MATCHED VIA OPEN PAYMENTS ADDRESS: {len(matched_orgs)} / {max_queries} sampled")
print(f"=========================================================")

# Save output
with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    if matched_orgs:
        writer = csv.DictWriter(f, fieldnames=list(matched_orgs[0].keys()))
        writer.writeheader()
        writer.writerows(matched_orgs)

print(f"Saved Type 2 Organization matches to: {OUT_CSV}")

print("\nSample Matched Type 2 Organizations:")
for m in matched_orgs[:10]:
    print(f"  CNM {m['first_name']} {m['last_name']} ({m['open_payments_address']}) -> Type 2 Org: {m['type2_organization_name']} [NPI: {m['type2_organization_npi']}]")
