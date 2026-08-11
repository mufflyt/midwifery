#!/usr/bin/env python3
# =============================================================================
# Build Midwife Hospital Affiliations Dataset (NPI -> CMS CCN -> OB Hospital)
# =============================================================================
import csv
import os

MIDWIVES_FILE = "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
FACILITY_AFFIL_FILE = "data/CMS_Facility_Affiliation.csv"
OB_HOSPITALS_FILE = "artifacts/ob_hospitals_geocoded.csv"
OUT_FILE = "artifacts/midwife_hospital_affiliations.csv"

print("=== Building Midwife Hospital & Health System Affiliation Linkages ===")

# 1. Load OB Hospital Lookup by CCN (prvdr_num)
ob_hospitals = {}
with open(OB_HOSPITALS_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        ccn = r.get("prvdr_num", "").strip().zfill(6)
        if ccn:
            ob_hospitals[ccn] = {
                "hospital_name": r.get("fac_name"),
                "hospital_address": r.get("geocode_address_1"),
                "hospital_city": r.get("geocode_city"),
                "hospital_state": r.get("geocode_state"),
                "hospital_zip": r.get("geocode_zip"),
                "hospital_county_fips": r.get("county_fips"),
                "latitude": r.get("latitude"),
                "longitude": r.get("longitude")
            }

print(f"Loaded {len(ob_hospitals)} OB hospitals by CMS CCN.")

# 2. Load Cohort Midwives
coh_npis = {}
with open(MIDWIVES_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") == "ACTIVE" and r.get("linkage_tier") == "primary_midwifery":
            npi = r.get("npi", "").strip()
            if npi:
                coh_npis[npi] = {
                    "certification_number": r.get("certification_number"),
                    "first_name": r.get("first_name"),
                    "last_name": r.get("last_name"),
                    "nppes_state": r.get("state")
                }

print(f"Loaded {len(coh_npis)} active cohort midwives.")

# 3. Match CMS Facility Affiliations
matched_records = []
matched_npis = set()
matched_ob_hospitals = set()

with open(FACILITY_AFFIL_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        npi = r.get("NPI", "").strip()
        if npi in coh_npis:
            mw = coh_npis[npi]
            ccn_raw = r.get("Facility Affiliations Certification Number", "").strip()
            ccn = ccn_raw.zfill(6) if ccn_raw else ""
            
            hosp_info = ob_hospitals.get(ccn, {})
            
            matched_npis.add(npi)
            if hosp_info:
                matched_ob_hospitals.add(ccn)
                
            matched_records.append({
                "certification_number": mw["certification_number"],
                "npi": npi,
                "first_name": mw["first_name"],
                "last_name": mw["last_name"],
                "nppes_state": mw["nppes_state"],
                "facility_type": r.get("facility_type", ""),
                "cms_ccn": ccn,
                "hospital_name": hosp_info.get("hospital_name", ""),
                "hospital_address": hosp_info.get("hospital_address", ""),
                "hospital_city": hosp_info.get("hospital_city", ""),
                "hospital_state": hosp_info.get("hospital_state", ""),
                "hospital_zip": hosp_info.get("hospital_zip", ""),
                "hospital_county_fips": hosp_info.get("hospital_county_fips", ""),
                "hospital_latitude": hosp_info.get("latitude", ""),
                "hospital_longitude": hosp_info.get("longitude", ""),
                "is_matched_ob_hospital": "Yes" if hosp_info else "No"
            })

print(f"\nMatch Results:")
print(f"  - Midwives with CMS Hospital/Facility Linkage: {len(matched_npis)} / {len(coh_npis)} ({len(matched_npis)/len(coh_npis)*100:.2f}%)")
print(f"  - Total Affiliation Records: {len(matched_records)}")
print(f"  - Unique OB Hospitals Linked: {len(matched_ob_hospitals)}")

# Write output CSV
with open(OUT_FILE, "w", newline="", encoding="utf-8") as f:
    if matched_records:
        writer = csv.DictWriter(f, fieldnames=list(matched_records[0].keys()))
        writer.writeheader()
        writer.writerows(matched_records)

print(f"\nSaved hospital affiliation dataset to: {OUT_FILE}")

# Print sample hospital matches
print("\nSample Matched Hospital Affiliations:")
ob_matches = [rec for rec in matched_records if rec["is_matched_ob_hospital"] == "Yes"]
for rec in ob_matches[:10]:
    print(f"  CNM {rec['first_name']} {rec['last_name']} ({rec['nppes_state']}) -> {rec['hospital_name']} ({rec['hospital_city']}, {rec['hospital_state']}) [CCN: {rec['cms_ccn']}]")
