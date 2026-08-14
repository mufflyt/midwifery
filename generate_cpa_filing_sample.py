#!/usr/bin/env python3
# =============================================================================
# OB/GYN Collaborative Practice Agreement (CPA) Filing Data Structure & Sample
# =============================================================================
import csv

cpa_filings_sample = [
    {
        "CPA_Filing_ID": "LA-CPA-2026-0814-01",
        "State_Jurisdiction": "Louisiana State Board of Nursing (LSBN)",
        "APRN_CNM_Name": "CNM Jimi Aucoin",
        "APRN_CNM_NPI": "1801256144",
        "APRN_License_Num": "LA-APRN-CNM-CNM2918",
        "Collaborating_OBGYN_Physician": "Dr. Robert Vance, MD",
        "Physician_Medical_License": "LA-MD-39102",
        "Physician_NPI": "1487029381",
        "Physician_Hospital_Affiliation": "Woman's Hospital (Baton Rouge, LA)",
        "Practice_Location": "Woman's Hospital Campus, Baton Rouge, LA 70817",
        "Prescriptive_Authority_Scope": "Schedule II-V Legend Drugs & Controlled Substances",
        "Obstetric_Consultation_Protocol": "Mandatory OB/GYN MFM Consultation for High-Risk Complications",
        "CPA_Execution_Date": "2026-01-15",
        "CPA_Status": "Active Validated Filing"
    },
    {
        "CPA_Filing_ID": "TX-CPA-2026-0412-09",
        "State_Jurisdiction": "Texas Board of Nursing (TX BON)",
        "APRN_CNM_Name": "CNM Sarah Elizabeth Jenkins",
        "APRN_CNM_NPI": "1497820194",
        "APRN_License_Num": "TX-APRN-CNM-12849",
        "Collaborating_OBGYN_Physician": "Dr. Michael Chen, MD",
        "Physician_Medical_License": "TX-MD-M81920",
        "Physician_NPI": "1821094830",
        "Physician_Hospital_Affiliation": "Texas Health Presbyterian Hospital Dallas",
        "Practice_Location": "8200 Walnut Hill Ln, Dallas, TX 75231",
        "Prescriptive_Authority_Scope": "Schedule III-V Prescriptive Authority",
        "Obstetric_Consultation_Protocol": "Immediate Physician Transfer Protocol for Operative Deliveries",
        "CPA_Execution_Date": "2026-02-01",
        "CPA_Status": "Active Validated Filing"
    },
    {
        "CPA_Filing_ID": "FL-CPA-2026-0918-04",
        "State_Jurisdiction": "Florida Department of Health (FL DOH MQA)",
        "APRN_CNM_Name": "CNM Maria Rodriguez",
        "APRN_CNM_NPI": "1205938210",
        "APRN_License_Num": "FL-APRN-CNM-92810",
        "Collaborating_OBGYN_Physician": "Dr. Amanda Miller, MD",
        "Physician_Medical_License": "FL-ME-102938",
        "Physician_NPI": "1396820193",
        "Physician_Hospital_Affiliation": "Orlando Health Winnie Palmer Hospital for Women & Babies",
        "Practice_Location": "83 W Miller St, Orlando, FL 32806",
        "Prescriptive_Authority_Scope": "Schedule II-V Controlled Substances & Legend Protocol",
        "Obstetric_Consultation_Protocol": "Joint Clinical Management Protocol for VBAC & Preeclampsia",
        "CPA_Execution_Date": "2026-03-10",
        "CPA_Status": "Active Validated Filing"
    }
]

out_csv = "artifacts/obgyn_cpa_filings_schema_and_sample.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(cpa_filings_sample[0].keys()))
    writer.writeheader()
    writer.writerows(cpa_filings_sample)

print(f"=== Successfully generated OB/GYN CPA Filings Data Report: {out_csv} ===")
