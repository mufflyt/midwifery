#!/usr/bin/env python3
# =============================================================================
# CMS Open Payments Covered Recipient Profile Harvester for Midwife Employers
# =============================================================================
import requests
import csv
import os
import sys

OPEN_PAYMENTS_PROFILE_URL = "https://download.cms.gov/openpayments/PHPRFL_P06302026_06032026/OP_CVRD_RCPNT_PRFL_SPLMTL_P06302026_06032026.csv"
MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
LOCAL_CSV = "data/CMS_Open_Payments_Profile_Supplement.csv"
OUT_MATCHES = "artifacts/cohort_midwives_open_payments_employers.csv"

print("=== CMS Open Payments Covered Recipient Profile Harvester ===")

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

# 2. Download / Stream CMS Open Payments Covered Recipient Profile Supplement
if not os.path.exists(LOCAL_CSV):
    print(f"Downloading Open Payments Profile Supplement from:\n  {OPEN_PAYMENTS_PROFILE_URL}")
    r = requests.get(OPEN_PAYMENTS_PROFILE_URL, stream=True, timeout=60)
    print(f"  HTTP Status: {r.status_code}")
    if r.status_code == 200:
        with open(LOCAL_CSV, "wb") as f:
            for chunk in r.iter_content(chunk_size=2 * 1024 * 1024):
                if chunk:
                    f.write(chunk)
        print(f"Downloaded and saved to {LOCAL_CSV}.")
    else:
        sys.exit(f"Failed to download Open Payments file (Status {r.status_code}).")

# 3. Match Cohort NPIs in Open Payments Profile File
print("\nProcessing CMS Open Payments Covered Recipient Profile File...")

matched_open_payments = []
with open(LOCAL_CSV, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    headers = reader.fieldnames
    print(f"Open Payments Profile Headers: {headers[:15] if headers else 'None'}")
    
    for row in reader:
        # Check potential NPI column names
        npi = row.get("Covered_Recipient_NPI", row.get("Covered_Recipient_Profile_ID", row.get("NPI", ""))).strip()
        if npi in coh_npis:
            mw = coh_npis[npi]
            
            # Extract employer / business / facility fields
            biz_name = row.get("Covered_Recipient_Primary_Practice_Location_Name", row.get("Principal_Practice_Location_Business_Name", row.get("Teaching_Hospital_Name", ""))).strip()
            addr1 = row.get("Covered_Recipient_Primary_Practice_Location_Address_Line1", "").strip()
            city = row.get("Covered_Recipient_Primary_Practice_Location_City", "").strip()
            state = row.get("Covered_Recipient_Primary_Practice_Location_State", "").strip()
            zip_code = row.get("Covered_Recipient_Primary_Practice_Location_Zip_Code", "").strip()
            spec = row.get("Covered_Recipient_Specialty_1", row.get("Covered_Recipient_Primary_Type_1", "")).strip()
            
            matched_open_payments.append({
                "certification_number": mw["cert"],
                "npi": npi,
                "first_name": mw["first"],
                "last_name": mw["last"],
                "nppes_state": mw["state"],
                "open_payments_employer_name": biz_name,
                "op_address": addr1,
                "op_city": city,
                "op_state": state,
                "op_zip": zip_code,
                "op_specialty": spec
            })

print(f"\n=========================================================")
print(f"  OPEN PAYMENTS EMPLOYER MATCHES FOUND: {len(matched_open_payments)} records")
print(f"  UNIQUE MIDWIVES LINKED TO EMPLOYERS: {len(set(r['npi'] for r in matched_open_payments))} / {N_cohort}")
print(f"=========================================================")

# Save output artifact
with open(OUT_MATCHES, "w", newline="", encoding="utf-8") as f:
    if matched_open_payments:
        writer = csv.DictWriter(f, fieldnames=list(matched_open_payments[0].keys()))
        writer.writeheader()
        writer.writerows(matched_open_payments)

print(f"\nSaved Open Payments employer matches to: {OUT_MATCHES}")

print("\nSample Open Payments Midwife Employer Matches:")
for rec in matched_open_payments[:15]:
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['op_city']}, {rec['op_state']}) -> Employer: {rec['open_payments_employer_name']} [{rec['op_address']}]")
