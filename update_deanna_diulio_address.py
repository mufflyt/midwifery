#!/usr/bin/env python3
# =============================================================================
# Update Deanna DiUlio, CNM practice location to Wolf Point, MT
# =============================================================================
import csv

v4_file = "artifacts/cohort_midwife_facility_attributions_final_v4.csv"
geo_file = "artifacts/amcb_npi_geography.csv"

# 1. Update Geography File
updated_geo = []
with open(geo_file, "r", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    fields_geo = reader.fieldnames
    for r in reader:
        if r.get("npi") == "1376072587" or "DIULIO" in r.get("last_name", "").upper():
            r["practice_address_1"] = "301 KNAPP ST"
            r["practice_city"] = "WOLF POINT"
            r["practice_state"] = "MT"
            r["practice_zip"] = "59201"
        updated_geo.append(r)

with open(geo_file, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields_geo)
    writer.writeheader()
    writer.writerows(updated_geo)

print("Updated amcb_npi_geography.csv for Deanna DiUlio (NPI: 1376072587).")

# 2. Update Master v4 File
updated_v4 = []
with open(v4_file, "r", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    fields_v4 = reader.fieldnames
    for r in reader:
        if r.get("npi") == "1376072587" or "DIULIO" in r.get("last_name", "").upper():
            r["nppes_practice_address"] = "301 KNAPP ST"
            r["nppes_city"] = "WOLF POINT"
            r["nppes_state"] = "MT"
            r["nppes_zip"] = "59201"
            r["attributed_hospital_name"] = "TRINITY HOSPITAL"
            r["cms_ccn"] = "271341"
        updated_v4.append(r)

with open(v4_file, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields_v4)
    writer.writeheader()
    writer.writerows(updated_v4)

print("Updated Master v4 dataset for Deanna DiUlio -> 301 KNAPP ST, Wolf Point, MT 59201.")
