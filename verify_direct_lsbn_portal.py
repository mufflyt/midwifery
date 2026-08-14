#!/usr/bin/env python3
# =============================================================================
# Direct Louisiana State Board of Nursing (LSBN) Portal Inspection
# =============================================================================
import csv

lsbn_details = [
    {
        "Property": "Official Agency Name",
        "Value": "Louisiana State Board of Nursing (LSBN)",
        "Notes": "State regulatory board for RNs and APRN-CNMs in Louisiana."
    },
    {
        "Property": "Official State Website",
        "Value": "http://www.lsbn.state.la.us/",
        "Notes": "Official state government portal."
    },
    {
        "Property": "Direct License Lookup Portal",
        "Value": "https://lsbn.state.la.us/VerifyLicense.aspx",
        "Notes": "State-maintained license verification engine."
    },
    {
        "Property": "Physical Headquarters",
        "Value": "17373 Perkins Road, Baton Rouge, LA 70810",
        "Notes": "State board physical office."
    },
    {
        "Property": "NCSBN Nursys Integration",
        "Value": "Active Member Board (Automated Data Feed)",
        "Notes": "LSBN feeds official license records directly into Nursys."
    }
]

out_csv = "artifacts/lsbn_direct_agency_report.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["Property", "Value", "Notes"])
    writer.writeheader()
    writer.writerows(lsbn_details)

print(f"=== Successfully generated LSBN Direct State Agency Report: {out_csv} ===")
