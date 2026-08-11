#!/usr/bin/env python3
# =============================================================================
# CMS Open Payments General Payment Data (Sunshine Act) Employer & Hospital Harvester
# =============================================================================
import requests
import csv
import os
import sys

OP_GNRL_2024_URL = "https://download.cms.gov/openpayments/PGYR2024_P06302026_06032026/OP_DTL_GNRL_PGYR2024_P06302026_06032026.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
LOCAL_CSV = "data/CMS_Open_Payments_General_2024.csv"
OUT_MATCHES = "artifacts/cohort_midwives_open_payments_general_2024.csv"

print("=== CMS Open Payments General Payments Employer & Hospital Harvester ===")

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

# 2. Stream Open Payments General Payment Data
print(f"Streaming and filtering CMS Open Payments 2024 General Payments from:\n  {OP_GNRL_2024_URL}")

r = requests.get(OP_GNRL_2024_URL, stream=True, timeout=60)
print(f"  HTTP Status: {r.status_code}")

if r.status_code != 200:
    sys.exit(f"Failed to stream Open Payments 2024 file (Status {r.status_code}).")

matched_records = []
line_count = 0

lines = (line.decode('utf-8', errors='ignore') for line in r.iter_lines())
reader = csv.DictReader(lines)

headers = reader.fieldnames
print(f"Open Payments General File Headers: {headers[:15] if headers else 'None'}\n")

for row in reader:
    line_count += 1
    if line_count % 1000000 == 0:
        print(f"  Processed {line_count:,} rows...")
        
    npi = row.get("Covered_Recipient_NPI", "").strip()
    if npi in coh_npis:
        mw = coh_npis[npi]
        hosp_name = row.get("Teaching_Hospital_Name", "").strip()
        biz_name = row.get("Principal_Practice_Location_Business_Name", "").strip()
        addr1 = row.get("Recipient_Primary_Business_Street_Address_Line1", "").strip()
        city = row.get("Recipient_City", "").strip()
        state = row.get("Recipient_State", "").strip()
        zip_code = row.get("Recipient_Zip_Code", "").strip()
        amt = row.get("Total_Amount_of_Payment_USDollars", "").strip()
        payer = row.get("Applicable_Manufacturer_or_Applicable_GPO_Making_Payment_Name", "").strip()
        
        matched_records.append({
            "certification_number": mw["cert"],
            "npi": npi,
            "first_name": mw["first"],
            "last_name": mw["last"],
            "nppes_state": mw["state"],
            "teaching_hospital_name": hosp_name,
            "principal_practice_business_name": biz_name,
            "recipient_city": city,
            "recipient_state": state,
            "recipient_zip": zip_code,
            "payment_amount": amt,
            "payer_manufacturer": payer
        })

print(f"\n=========================================================")
print(f"  OPEN PAYMENTS 2024 MATCHES FOUND: {len(matched_records)} records")
print(f"  UNIQUE MIDWIVES LINKED TO EMPLOYERS/HOSPITALS: {len(set(r['npi'] for r in matched_records))} / {N_cohort}")
print(f"=========================================================")

# Save output
with open(OUT_MATCHES, "w", newline="", encoding="utf-8") as f:
    if matched_records:
        writer = csv.DictWriter(f, fieldnames=list(matched_records[0].keys()))
        writer.writeheader()
        writer.writerows(matched_records)

print(f"\nSaved Open Payments 2024 matches to: {OUT_MATCHES}")

print("\nSample Open Payments Midwife Employer & Hospital Matches:")
for rec in matched_records[:15]:
    hosp = rec['teaching_hospital_name'] if rec['teaching_hospital_name'] else rec['principal_practice_business_name']
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['recipient_city']}, {rec['recipient_state']}) -> Facility/Employer: {hosp} [Payer: {rec['payer_manufacturer']}]")
