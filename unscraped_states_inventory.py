#!/usr/bin/env python3
# =============================================================================
# Remaining 10 Unscraped States Inventory & Data Access Analysis
# =============================================================================
import csv

unscraped_states = [
    {"state": "AK", "state_name": "Alaska", "bon_agency": "Alaska Board of Nursing", "reason": "Small rural roster; scheduled for Wave 3 scraper."},
    {"state": "HI", "state_name": "Hawaii", "bon_agency": "Hawaii Department of Commerce & Consumer Affairs (PVL)", "reason": "Island jurisdiction; PVL web form portal."},
    {"state": "RI", "state_name": "Rhode Island", "bon_agency": "Rhode Island Department of Health", "reason": "Small New England roster; health.ri.gov licensing lookup."},
    {"state": "DE", "state_name": "Delaware", "bon_agency": "Delaware Division of Professional Regulation", "reason": "DPR DELPROS portal."},
    {"state": "VT", "state_name": "Vermont", "bon_agency": "Vermont Office of Professional Regulation (SOS)", "reason": "SOS licensing lookup portal."},
    {"state": "ND", "state_name": "North Dakota", "bon_agency": "North Dakota Board of Nursing", "reason": "Nursys Compact state; scheduled for Wave 3."},
    {"state": "SD", "state_name": "South Dakota", "bon_agency": "South Dakota Board of Nursing", "reason": "Nursys Compact state; scheduled for Wave 3."},
    {"state": "WV", "state_name": "West Virginia", "bon_agency": "West Virginia Board of Examiners for RNs", "reason": "WVRN portal search."},
    {"state": "WY", "state_name": "Wyoming", "bon_agency": "Wyoming State Board of Nursing", "reason": "WSBN license verification portal."},
    {"state": "DC", "state_name": "District of Columbia", "bon_agency": "DC Board of Nursing (DC Health)", "reason": "District jurisdiction; DC Health portal."}
]

out_csv = "artifacts/remaining_unscraped_states_inventory.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["state", "state_name", "bon_agency", "reason"])
    writer.writeheader()
    writer.writerows(unscraped_states)

print(f"=== Successfully generated Remaining 10 Unscraped States Inventory: {out_csv} ===")
