#!/usr/bin/env python3
# =============================================================================
# High-Impact External Data Source Expansion Roadmap
# =============================================================================
import json

future_sources = [
    {
        "priority": 1,
        "name": "HRSA Health Professional Shortage Area (HPSA) & MUA Files",
        "agency": "Health Resources and Services Administration (HRSA)",
        "url": "https://data.hrsa.gov/topics/health-workforce/hpsa",
        "value": "Classifies every CNM practice location into Maternity HPSAs and Medically Underserved Areas."
    },
    {
        "priority": 2,
        "name": "CDC WONDER Natality Microdata (County Birth Rates & Attender Types)",
        "agency": "Centers for Disease Control and Prevention (CDC NCHS)",
        "url": "https://wonder.cdc.gov/natality.html",
        "value": "Provides exact denominators for midwives per 1,000 live births & birth outcome rates."
    },
    {
        "priority": 3,
        "name": "CMS Provider of Services (POS) OB Unit & NICU Capabilities",
        "agency": "Centers for Medicare & Medicaid Services (CMS)",
        "url": "https://data.cms.gov/provider-characteristics",
        "value": "Tags hospitals with OB delivery unit status, bed count, and NICU Level (I to IV)."
    },
    {
        "priority": 4,
        "name": "50-State Nursing Board License Renewal Rosters",
        "agency": "State Departments of Health / Boards of Nursing",
        "url": "State DOH Portals",
        "value": "Validates exact active licensure, renewal dates, and secondary state licenses."
    },
    {
        "priority": 5,
        "name": "USDA ERS Rural-Urban Continuum Codes (RUCC 2023) & Frontier Codes",
        "agency": "United States Department of Agriculture (USDA ERS)",
        "url": "https://www.ers.usda.gov/data-products/rural-urban-continuum-codes/",
        "value": "Classifies practices into Urban, Rural, and Frontier maternity care deserts."
    }
]

print("=== Recommended External Data Sources to Ingest ===")
for s in future_sources:
    print(f"[{s['priority']}] {s['name']}")
    print(f"    Agency: {s['agency']}")
    print(f"    URL:    {s['url']}")
    print(f"    Value:  {s['value']}\n")
