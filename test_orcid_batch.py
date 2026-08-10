#!/usr/bin/env python3
import requests
import csv
import json
import time

headers = {"Accept": "application/json"}

# Load sample midwives from cohort
mw_sample = []
with open("midwives.csv", "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("certification_number") and r.get("first_name") and r.get("last_name"):
            mw_sample.append({
                "cert": r["certification_number"],
                "first": r["first_name"].strip(),
                "last": r["last_name"].strip(),
                "cert_date": r.get("certification_date", "")
            })
        if len(mw_sample) >= 30:
            break

print(f"Loaded {len(mw_sample)} sample midwives. Querying ORCID Public API...")

orcid_matches = []

for mw in mw_sample:
    first, last = mw["first"], mw["last"]
    # Query 1: exact name query
    q = f'given-names:{first} AND family-name:{last}'
    url = f"https://pub.orcid.org/v3.0/search/?q={q}"
    
    try:
        r = requests.get(url, headers=headers, timeout=10)
        if r.status_code == 200:
            data = r.json()
            num_found = data.get("num-found", 0)
            results = data.get("result") or []
            
            if num_found > 0 and results:
                print(f"[Match Found] {first} {last} -> {num_found} ORCID candidate(s)")
                for item in results[:2]:
                    orcid_id = item.get("orcid-identifier", {}).get("path")
                    if not orcid_id: continue
                    
                    # Fetch education history for this ORCID ID
                    edu_url = f"https://pub.orcid.org/v3.0/{orcid_id}/educations"
                    r_edu = requests.get(edu_url, headers=headers, timeout=10)
                    if r_edu.status_code == 200:
                        edu_data = r_edu.json()
                        summaries = edu_data.get("education-summary") or []
                        
                        edu_list = []
                        for ed in summaries:
                            org = ed.get("organization", {}).get("name")
                            role = ed.get("role-title")
                            end_year = ed.get("end-date", {}).get("year", {}).get("value") if ed.get("end-date") else None
                            start_year = ed.get("start-date", {}).get("year", {}).get("value") if ed.get("start-date") else None
                            edu_list.append({
                                "org": org,
                                "role": role,
                                "start_year": start_year,
                                "end_year": end_year
                            })
                            
                        orcid_matches.append({
                            "cert": mw["cert"],
                            "first": first,
                            "last": last,
                            "orcid_id": orcid_id,
                            "educations": edu_list
                        })
                        print(f"  ORCID iD: {orcid_id} | Education records: {len(edu_list)}")
                        for e in edu_list:
                            print(f"    - Degree: {e['role']} | Org: {e['org']} | Grad Year: {e['end_year']}")
        time.sleep(0.2)
    except Exception as e:
        print(f"Error querying {first} {last}: {e}")

print(f"\nTotal ORCID profile matches found: {len(orcid_matches)}")
