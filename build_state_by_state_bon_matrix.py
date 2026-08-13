#!/usr/bin/env python3
# =============================================================================
# State-by-State Board of Nursing (BON) Data Ingestion Matrix
# =============================================================================
import csv
import json

state_bon_matrix = [
    # Group A: Bulk Public Open Data Downloads
    {"state": "WA", "bon_name": "Washington Department of Health", "access_type": "Bulk CSV Download", "portal_url": "https://data.wa.gov/health-care"},
    {"state": "FL", "bon_name": "Florida Department of Health Medical Quality Assurance", "access_type": "Bulk CSV Download", "portal_url": "https://flhealthsource.gov/media/data-downloads/"},
    {"state": "TX", "bon_name": "Texas Board of Nursing", "access_type": "Bulk CSV Download", "portal_url": "https://data.texas.gov/"},
    {"state": "NY", "bon_name": "New York State Education Dept (NYSED)", "access_type": "Bulk Public Database", "portal_url": "http://www.op.nysed.gov/opsearches.htm"},
    {"state": "NC", "bon_name": "North Carolina Board of Nursing", "access_type": "Bulk Open Data", "portal_url": "https://www.ncbon.com/"},
    {"state": "VA", "bon_name": "Virginia Department of Health Professions", "access_type": "Bulk License File", "portal_url": "https://www.dhp.virginia.gov/"},
    {"state": "OH", "bon_name": "Ohio Board of Nursing", "access_type": "Bulk E-License Portal", "portal_url": "https://elicense.ohio.gov/"},
    {"state": "IN", "bon_name": "Indiana Professional Licensing Agency", "access_type": "Bulk Open Data", "portal_url": "https://www.in.gov/pla/"},
    {"state": "MA", "bon_name": "Massachusetts Board of Registration in Nursing", "access_type": "Bulk Open Data", "portal_url": "https://www.mass.gov/orgs/board-of-registration-in-nursing"},
    {"state": "OR", "bon_name": "Oregon State Board of Nursing", "access_type": "Bulk Open Data", "portal_url": "https://www.oregon.gov/osbn/"},
    {"state": "AZ", "bon_name": "Arizona State Board of Nursing", "access_type": "Bulk Open Data", "portal_url": "https://www.azbn.gov/"},

    # Group B: Nursys Compact & Participating States
    {"state": "MT", "bon_name": "Montana Board of Nursing", "access_type": "Nursys / Portal Scraper", "portal_url": "https://ebiz.mt.gov/pol/"},
    {"state": "CO", "bon_name": "Colorado Division of Professions (DORA)", "access_type": "Nursys / Portal Scraper", "portal_url": "https://apps.colorado.gov/dora/licensing/lookup/licenselookup.aspx"},
    {"state": "UT", "bon_name": "Utah Division of Professional Licensing", "access_type": "Nursys", "portal_url": "https://dopl.utah.gov/"},
    {"state": "ID", "bon_name": "Idaho Board of Nursing", "access_type": "Nursys", "portal_url": "https://ibn.idaho.gov/"},
    {"state": "WY", "bon_name": "Wyoming State Board of Nursing", "access_type": "Nursys", "portal_url": "https://wsbn.wyo.gov/"},
    {"state": "ND", "bon_name": "North Dakota Board of Nursing", "access_type": "Nursys", "portal_url": "https://www.ndbon.org/"},
    {"state": "SD", "bon_name": "South Dakota Board of Nursing", "access_type": "Nursys", "portal_url": "https://doh.sd.gov/boards/nursing/"},
    {"state": "NE", "bon_name": "Nebraska Department of Health and Human Services", "access_type": "Nursys", "portal_url": "https://dhhs.ne.gov/"},
    {"state": "IA", "bon_name": "Iowa Board of Nursing", "access_type": "Nursys", "portal_url": "https://nursing.iowa.gov/"},
    {"state": "KS", "bon_name": "Kansas State Board of Nursing", "access_type": "Nursys", "portal_url": "https://ksbn.kansas.gov/"},
    {"state": "MO", "bon_name": "Missouri State Board of Nursing", "access_type": "Nursys", "portal_url": "https://pr.mo.gov/nursing.asp"},
    {"state": "AR", "bon_name": "Arkansas State Board of Nursing", "access_type": "Nursys", "portal_url": "https://www.healthy.arkansas.gov/"},
    {"state": "LA", "bon_name": "Louisiana State Board of Nursing", "access_type": "Nursys", "portal_url": "http://www.lsbn.state.la.us/"},
    {"state": "MS", "bon_name": "Mississippi Board of Nursing", "access_type": "Nursys", "portal_url": "https://www.msbn.ms.gov/"},
    {"state": "AL", "bon_name": "Alabama Board of Nursing", "access_type": "Nursys", "portal_url": "https://www.abn.alabama.gov/"},
    {"state": "GA", "bon_name": "Georgia Board of Nursing", "access_type": "Nursys", "portal_url": "https://gbn.georgia.gov/"},
    {"state": "SC", "bon_name": "South Carolina Board of Nursing", "access_type": "Nursys", "portal_url": "https://llr.sc.gov/nurse/"},
    {"state": "TN", "bon_name": "Tennessee Board of Nursing", "access_type": "Nursys", "portal_url": "https://www.tn.gov/health/health-program-areas/health-professional-boards/nursing-board.html"},
    {"state": "KY", "bon_name": "Kentucky Board of Nursing", "access_type": "Nursys", "portal_url": "https://kbn.ky.gov/"},
    {"state": "WV", "bon_name": "West Virginia Board of Examiners for Registered Nurses", "access_type": "Nursys", "portal_url": "https://wvrnboard.wv.gov/"},
    {"state": "MD", "bon_name": "Maryland Board of Nursing", "access_type": "Nursys", "portal_url": "https://mbon.maryland.gov/"},
    {"state": "DE", "bon_name": "Delaware Board of Nursing", "access_type": "Nursys", "portal_url": "https://dpr.delaware.gov/boards/nursing/"},
    {"state": "NH", "bon_name": "New Hampshire Board of Nursing", "access_type": "Nursys", "portal_url": "https://www.oplc.nh.gov/board-nursing"},
    {"state": "VT", "bon_name": "Vermont Board of Nursing", "access_type": "Nursys", "portal_url": "https://sos.vermont.gov/nursing/"},
    {"state": "ME", "bon_name": "Maine State Board of Nursing", "access_type": "Nursys", "portal_url": "https://www.maine.gov/boardofnursing/"},

    # Group C: Custom Web Portal Scrapers
    {"state": "CA", "bon_name": "California Board of Registered Nursing (DCA BreEZe)", "access_type": "Browser Scraper (BreEZe)", "portal_url": "https://search.dca.ca.gov/"},
    {"state": "IL", "bon_name": "Illinois Dept of Financial & Professional Regulation (IDFPR)", "access_type": "Browser Scraper (IDFPR)", "portal_url": "https://idfpr.illinois.gov/"},
    {"state": "MI", "bon_name": "Michigan LARA Licensing Portal", "access_type": "Browser Scraper (LARA)", "portal_url": "https://www.michigan.gov/lara"},
    {"state": "PA", "bon_name": "Pennsylvania PALS Licensing System", "access_type": "Browser Scraper (PALS)", "portal_url": "https://www.pals.pa.gov/"},
    {"state": "NJ", "bon_name": "New Jersey Division of Consumer Affairs", "access_type": "Browser Scraper (MyLicense)", "portal_url": "https://www.njconsumeraffairs.gov/nur"},
    {"state": "MN", "bon_name": "Minnesota Board of Nursing", "access_type": "Browser Scraper", "portal_url": "https://mn.gov/boards/nursing/"}
]

print(f"=== State-by-State Board of Nursing (BON) Ingestion Strategy ({len(state_bon_matrix)} States) ===")

group_counts = {}
for item in state_bon_matrix:
    t = item["access_type"]
    group_counts[t] = group_counts.get(t, 0) + 1

for k, v in group_counts.items():
    print(f"  {k}: {v} States")

out_csv = "artifacts/state_by_state_bon_strategy.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=state_bon_matrix[0].keys())
    writer.writeheader()
    writer.writerows(state_bon_matrix)

print(f"\nWritten state-by-state strategy matrix to: {out_csv}")
