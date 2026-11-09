#!/usr/bin/env python3
# =============================================================================
# CMS Open Payments General Payment Data (Sunshine Act) Employer & Hospital Harvester
# =============================================================================
# One program year per run, OPEN_PAYMENTS_YEAR (default 2024). The download
# URL is looked up live from CMS's own metastore catalog rather than
# hardcoded -- the publication-date segment in the URL
# ("PGYR2024_P06302026_06032026") is not predictable release to release, and
# archive_revalidation_reassignment.R already hit exactly this failure mode
# once this month when CMS restructured a different catalog the same way.
import requests
import csv
import os
import sys

PROGRAM_YEAR = os.environ.get("OPEN_PAYMENTS_YEAR", "2024")
# Glob rather than a pinned filename: the crosswalk's own name carries the
# years it covers ("...years-2007-2026.csv"), which changes as the cohort is
# re-pinned. Newest by mtime, same convention build_organization_affiliation_resolver.R uses.
import glob
_crosswalk_candidates = sorted(
    glob.glob("artifacts/amcb_npi_crosswalk_*panel*.csv"), key=os.path.getmtime, reverse=True)
if not _crosswalk_candidates:
    sys.exit("no artifacts/amcb_npi_crosswalk_*panel*.csv found")
MIDWIVES_FILE = _crosswalk_candidates[0]
LOCAL_CSV = f"data/CMS_Open_Payments_General_{PROGRAM_YEAR}.csv"
OUT_MATCHES = f"artifacts/cohort_midwives_open_payments_general_{PROGRAM_YEAR}.csv"

print(f"=== CMS Open Payments General Payments Employer & Hospital Harvester ({PROGRAM_YEAR}) ===")


def find_general_payments_url(year):
    """Look up this program year's "General Payment Data" download URL from
    CMS's own metastore catalog, rather than guessing the publication-date
    segment of the URL."""
    catalog = requests.get(
        "https://openpaymentsdata.cms.gov/api/1/metastore/schemas/dataset/items",
        timeout=30).json()
    target_title = f"{year} General Payment Data"
    hits = [d for d in catalog if d.get("title") == target_title]
    if not hits:
        sys.exit(f"'{target_title}' not found in the Open Payments catalog. "
                  "Refusing to guess a URL rather than warehouse nothing and "
                  "report success.")
    item = requests.get(
        f"https://openpaymentsdata.cms.gov/api/1/metastore/schemas/dataset/items/{hits[0]['identifier']}",
        timeout=30).json()
    for dist in item.get("distribution", []):
        url = (dist.get("data", {}) or {}).get("downloadURL") or dist.get("downloadURL")
        if url and url.lower().endswith(".csv") and "DTL_GNRL" in url:
            return url
    sys.exit(f"No General Payment Data CSV distribution found for {year}.")


OP_GNRL_URL = find_general_payments_url(PROGRAM_YEAR)

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
print(f"Streaming and filtering CMS Open Payments {PROGRAM_YEAR} General Payments from:\n  {OP_GNRL_URL}")

r = requests.get(OP_GNRL_URL, stream=True, timeout=60)
print(f"  HTTP Status: {r.status_code}")

if r.status_code != 200:
    sys.exit(f"Failed to stream Open Payments {PROGRAM_YEAR} file (Status {r.status_code}).")

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
            "recipient_address": addr1,
            "recipient_city": city,
            "recipient_state": state,
            "recipient_zip": zip_code,
            "payment_amount": amt,
            "payer_manufacturer": payer
        })

print(f"\n=========================================================")
print(f"  OPEN PAYMENTS {PROGRAM_YEAR} MATCHES FOUND: {len(matched_records)} records")
print(f"  UNIQUE MIDWIVES LINKED TO EMPLOYERS/HOSPITALS: {len(set(r['npi'] for r in matched_records))} / {N_cohort}")
print(f"=========================================================")

# Save output
with open(OUT_MATCHES, "w", newline="", encoding="utf-8") as f:
    if matched_records:
        writer = csv.DictWriter(f, fieldnames=list(matched_records[0].keys()))
        writer.writeheader()
        writer.writerows(matched_records)

print(f"\nSaved Open Payments {PROGRAM_YEAR} matches to: {OUT_MATCHES}")

print("\nSample Open Payments Midwife Employer & Hospital Matches:")
for rec in matched_records[:15]:
    hosp = rec['teaching_hospital_name'] if rec['teaching_hospital_name'] else rec['principal_practice_business_name']
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['recipient_city']}, {rec['recipient_state']}) -> Facility/Employer: {hosp} [Payer: {rec['payer_manufacturer']}]")
