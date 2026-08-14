#!/usr/bin/env python3
# =============================================================================
# State Board of Nursing (BON) Extracted Fields Inventory Report
# =============================================================================
import csv

bon_fields = [
    {
        "Field_Name": "State License / Credential String",
        "Variable": "scraped_license_num",
        "Clinical_Value": "Uniquely identifies state APRN-CNM practice license.",
        "Sample_Value": "CO-RN-APRN-10542"
    },
    {
        "Field_Name": "Licensure & Practice Status",
        "Variable": "scraped_license_status",
        "Clinical_Value": "Confirms active legal authority to practice nurse-midwifery.",
        "Sample_Value": "Active Verified (BON Direct Scrape)"
    },
    {
        "Field_Name": "Nursys Multi-State Compact Privilege",
        "Variable": "tier2_compact_privilege",
        "Clinical_Value": "Identifies cross-border practice authority in 25+ Compact states.",
        "Sample_Value": "Multi-State Practice Privilege Active"
    },
    {
        "Field_Name": "License Expiration / Renewal Date",
        "Variable": "expiration_date",
        "Clinical_Value": "Tracks workforce retention & upcoming license expirations.",
        "Sample_Value": "12/2029"
    },
    {
        "Field_Name": "Initial State Licensure Date",
        "Variable": "firstissuedate",
        "Clinical_Value": "Measures clinician practice longevity and career vintage.",
        "Sample_Value": "06/2001"
    },
    {
        "Field_Name": "Mandatory Primary Practice Address",
        "Variable": "nppes_practice_address",
        "Clinical_Value": "Verifies physical employment location reported upon renewal.",
        "Sample_Value": "777 BANNOCK ST"
    },
    {
        "Field_Name": "Practice Municipality & ZIP Code",
        "Variable": "nppes_city / nppes_zip",
        "Clinical_Value": "Anchors practice location for travel time and isochrone mapping.",
        "Sample_Value": "DENVER, CO 80204"
    },
    {
        "Field_Name": "Prescriptive Authority (RXN)",
        "Variable": "prescriptive_authority_status",
        "Clinical_Value": "Verifies legal authority to prescribe legend drugs & contraceptives.",
        "Sample_Value": "Active RXN Prescriptive Authority"
    },
    {
        "Field_Name": "Board Discipline Flag",
        "Variable": "actiontaken",
        "Clinical_Value": "Identifies public disciplinary orders or clean practice standing.",
        "Sample_Value": "No / Clean Standing"
    },
    {
        "Field_Name": "State Licensing Board Jurisdiction",
        "Variable": "scraped_bon_state",
        "Clinical_Value": "Identifies specific state licensing authority.",
        "Sample_Value": "Colorado DORA / WA DOH"
    }
]

out_csv = "artifacts/bon_extracted_fields_inventory.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["Field_Name", "Variable", "Clinical_Value", "Sample_Value"])
    writer.writeheader()
    writer.writerows(bon_fields)

print(f"=== Generated State BON Extracted Fields Inventory: {out_csv} ===")
