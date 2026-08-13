#!/usr/bin/env python3
# =============================================================================
# Additional Data Sources for Physical Practice Address Verification
# =============================================================================
import json

address_verification_sources = [
    {
        "rank": 1,
        "name": "CMS Medicare Part D Prescriber Location File",
        "type": "Federal Prescription Billing Address",
        "value": "Verifies physical clinic address where CNMs write active Part D prescriptions."
    },
    {
        "rank": 2,
        "name": "50-State Board of Nursing License Practice Address Registries",
        "type": "State Licensure Mandatory Filings",
        "value": "Mandatory employment address reported during annual/biennial license renewal."
    },
    {
        "rank": 3,
        "name": "USPS CASS & National Change of Address (NCOA) DPV Engine",
        "type": "USPS Commercial Address Validation",
        "value": "Verifies physical commercial deliverability, building suite #, and ZIP+4 correctness."
    },
    {
        "rank": 4,
        "name": "CMS Ordering & Referring Provider File",
        "type": "Federal Lab & Imaging Ordering File",
        "value": "Contains practice addresses of clinicians ordering maternal labs & ultrasounds."
    },
    {
        "rank": 5,
        "name": "HRSA FQHC / RHC / IHS Tribal Facility Directory (SAM.gov)",
        "type": "Federal Health Center Physical Registry",
        "value": "Provides exact physical addresses for FQHCs, Rural Health Clinics, and IHS tribal centers."
    }
]

print("=== Recommended Data Sources to Verify Physical Practice Addresses ===")
for s in address_verification_sources:
    print(f"[{s['rank']}] {s['name']}")
    print(f"    Type:  {s['type']}")
    print(f"    Value: {s['value']}\n")
