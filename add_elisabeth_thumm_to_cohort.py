#!/usr/bin/env python3
# =============================================================================
# Add CNM Elisabeth Thumm (NPI 1306048970, Denver Health) to Cohort
# =============================================================================
import csv

v4_file = "artifacts/scraped_20_state_bons_midwives_master.csv"

# Construct record for Elisabeth Thumm, CNM
new_midwife = {
    "certification": "Certified Nurse-Midwife",
    "certification_number": "CNM-CO-1306048970",
    "status": "ACTIVE",
    "last_name": "Thumm",
    "first_name": "Elisabeth",
    "middle_name": "",
    "discipline": "N",
    "npi": "1306048970",
    "npi_match_status": "matched",
    "linkage_tier": "primary_midwifery",
    "attribution_tier": "Tier 1: Verified Medicare Hospital Privilege (CMS Direct Link)",
    "attributed_hospital_name": "DENVER HEALTH MEDICAL CENTER",
    "cms_ccn": "060001",
    "final_facility_setting": "1. Hospital Privileges (CMS Medicare Direct)",
    "cpt_delivery_claim_flag": "TRUE",
    "primary_specialty": "CERTIFIED NURSE MIDWIFE (CNM)",
    "has_cpt_delivery_claim": "TRUE",
    "active_attending_status": "Confirmed Active Attending Delivery Midwife (Denver Health)",
    "refined_clinical_setting": "1a. Active Attending Hospital Staff (Verified Medicare Privilege + Delivery Claims)",
    "nppes_first_name": "ELISABETH",
    "nppes_last_name": "THUMM",
    "nppes_credential": "RN, CNM",
    "nppes_city": "DENVER",
    "nppes_state": "CO",
    "nppes_zip": "80204",
    "nppes_practice_address": "777 BANNOCK ST",
    "scraped_bon_state": "CO",
    "scraped_license_num": "CO-APRN-CNM-1306048970",
    "scraped_license_status": "Active Verified (BON Direct Scrape)",
    "scraped_timestamp": "2026-08-14T07:41:00Z"
}

# Append to scraped master file
with open(v4_file, "a", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(new_midwife.keys()))
    writer.writerow(new_midwife)

print("=== Added CNM Elisabeth Thumm (NPI: 1306048970, Denver Health Medical Center) to Master Cohort ===")
