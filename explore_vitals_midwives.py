#!/usr/bin/env python3
# =============================================================================
# Vitals.com Provider DOB / Age & Profile Explorer (Standard Library)
# =============================================================================
import requests
import json
import csv
import re
import time
from html.parser import HTMLParser

headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
}

# Sample 10 midwives from our national cohort
mw_sample = []
with open("midwives.csv", "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("certification_number") and r.get("first_name") and r.get("last_name"):
            mw_sample.append({
                "cert": r["certification_number"],
                "first": r["first_name"].strip(),
                "last": r["last_name"].strip(),
                "city": r.get("city", "").strip(),
                "state": r.get("state", "").strip()
            })
        if len(mw_sample) >= 10:
            break

print("=== Vitals.com Profile Inspector & Search Test ===")
print(f"Testing {len(mw_sample)} sample midwives against Vitals.com search...\n")

s = requests.Session()

for mw in mw_sample:
    first, last, state = mw["first"], mw["last"], mw["state"]
    search_url = f"https://www.vitals.com/search?q={first}+{last}+{state}"
    
    print(f"Querying: {first} {last} ({state})")
    print(f"  URL: {search_url}")
    
    try:
        r = s.get(search_url, headers=headers, verify=False, timeout=10)
        print(f"  Status Code: {r.status_code}")
        
        if r.status_code == 200:
            html_text = r.text
            # Extract links matching /doctors/ or /midwives/
            profile_links = re.findall(r"href=[\"'](/doctors/[^\"']+|/midwives/[^\"']+|/providers/[^\"']+)[\"']", html_text)
            profile_links = list(set(profile_links))
            
            print(f"  Found {len(profile_links)} candidate profile links.")
            for pl in profile_links[:3]:
                print(f"    - {pl}")
                
            if profile_links:
                p_url = "https://www.vitals.com" + profile_links[0]
                print(f"  Fetching profile: {p_url}")
                pr = s.get(p_url, headers=headers, verify=False, timeout=10)
                if pr.status_code == 200:
                    text = pr.text
                    age_match = re.search(r"Age\s*[:\-\s]\s*(\d{2})|(\d{2})\s*years\s*old", text, re.I)
                    exp_match = re.search(r"(\d{1,2})\s*\+?\s*years?\s*(?:in\s*)?practice|experience", text, re.I)
                    grad_match = re.search(r"Graduated\s*(?:in\s*)?(\d{4})|Class\s*of\s*(\d{4})", text, re.I)
                    
                    print("  [Profile Inspection Results]:")
                    print(f"    - Age match: {age_match.groups() if age_match else 'None'}")
                    print(f"    - Experience match: {exp_match.groups() if exp_match else 'None'}")
                    print(f"    - Graduation match: {grad_match.groups() if grad_match else 'None'}")
        
        time.sleep(1)
    except Exception as e:
        print(f"  Error: {e}")
    print("-" * 60)
