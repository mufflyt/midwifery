#!/usr/bin/env python3
# =============================================================================
# NPI Number vs State License Number Formatting & Mapping Demonstration
# =============================================================================
import csv

mapping_samples = [
    {
        "Midwife_Name": "Elisabeth Brie Thumm, CNM",
        "NPI_Number_10_Digit": "1306048970",
        "State_License_Number": "CO-RN-APRN-10542",
        "Licensing_State": "CO",
        "Licensing_Agency": "Colorado Division of Professions (CO DORA)",
        "NPPES_Linkage_Status": "1-to-1 Perfect Match"
    },
    {
        "Midwife_Name": "Deanna DiUlio, CNM",
        "NPI_Number_10_Digit": "1043329170",
        "State_License_Number": "MT-RN-APRN-48192",
        "Licensing_State": "MT",
        "Licensing_Agency": "Montana State Board of Nursing (eBiz)",
        "NPPES_Linkage_Status": "1-to-1 Perfect Match"
    },
    {
        "Midwife_Name": "Jimi Aucoin, CNM",
        "NPI_Number_10_Digit": "1801256144",
        "State_License_Number": "LA-APRN-CNM-CNM2918",
        "Licensing_State": "LA",
        "Licensing_Agency": "Louisiana State Board of Nursing (LSBN)",
        "NPPES_Linkage_Status": "1-to-1 Perfect Match"
    },
    {
        "Midwife_Name": "Shannon Shepherd, CNM",
        "NPI_Number_10_Digit": "1114904976",
        "State_License_Number": "MT-RN-APRN-12009",
        "Licensing_State": "MT",
        "Licensing_Agency": "Montana State Board of Nursing (eBiz)",
        "NPPES_Linkage_Status": "1-to-1 Perfect Match"
    }
]

out_csv = "artifacts/npi_vs_state_license_mapping_sample.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(mapping_samples[0].keys()))
    writer.writeheader()
    writer.writerows(mapping_samples)

print(f"=== Successfully generated NPI vs State License Mapping Demonstration: {out_csv} ===")
