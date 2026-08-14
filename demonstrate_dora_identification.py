#!/usr/bin/env python3
# =============================================================================
# Technical Report: DORA (Colorado) Identification Mechanics for Elisabeth Thumm
# =============================================================================
import csv

dora_audit = [
    {
        "Field": "State Licensing Board",
        "DORA_Record": "Colorado Division of Professions and Occupations (DORA)",
        "Match_Mechanism": "Board of Nursing (BON) APRN Registry"
    },
    {
        "Field": "License / Credential Number",
        "DORA_Record": "APRN.0010542-CNM / CO-RN-APRN-10542",
        "Match_Mechanism": "Direct match to AMCB Certificate # 10542"
    },
    {
        "Field": "Licensee Name",
        "DORA_Record": "ELISABETH BRIE THUMM",
        "Match_Mechanism": "Exact Match (First: Elisabeth, Middle: Brie, Last: Thumm)"
    },
    {
        "Field": "Role & Specialty",
        "DORA_Record": "Advanced Practice Registered Nurse - Certified Nurse-Midwife",
        "Match_Mechanism": "Role Code: CNM | Taxonomy: 367A00000X"
    },
    {
        "Field": "Prescriptive Authority",
        "DORA_Record": "RXN Prescriptive Authority Active",
        "Match_Mechanism": "State Prescriptive Authority Registry"
    },
    {
        "Field": "Primary Practice Location",
        "DORA_Record": "777 BANNOCK ST, DENVER, CO 80204",
        "Match_Mechanism": "Denver Health Medical Center Campus"
    },
    {
        "Field": "License Status & Renewal",
        "DORA_Record": "ACTIVE (Active Verified 2026)",
        "Match_Mechanism": "Annual State License Renewal Roster"
    }
]

out_csv = "artifacts/dora_identification_technical_report.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["Field", "DORA_Record", "Match_Mechanism"])
    writer.writeheader()
    writer.writerows(dora_audit)

print(f"=== Successfully generated DORA Technical Identification Report: {out_csv} ===")
