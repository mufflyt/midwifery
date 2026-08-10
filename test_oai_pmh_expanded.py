#!/usr/bin/env python3
# =============================================================================
# Expanded OAI-PMH Harvester for Nursing & Midwifery Institutional Repositories
# =============================================================================
import requests
import xml.etree.ElementTree as ET
import re
import csv

REPOS = [
    {"name": "Yale University EliScholar", "url": "https://elischolar.library.yale.edu/do/oai/"},
    {"name": "UPenn ScholarlyCommons", "url": "https://repository.upenn.edu/do/oai/"},
    {"name": "OHSU Digital Collections", "url": "https://digitalcollections.ohsu.edu/oai"},
    {"name": "University of Minnesota Digital Conservancy", "url": "https://conservancy.umn.edu/oai/request"},
    {"name": "Vanderbilt University Institutional Repository", "url": "https://ir.vanderbilt.edu/oai/request"}
]

headers = {"User-Agent": "Mozilla/5.0"}

print("=== Expanded University OAI-PMH Metadata Harvester ===")

all_harvested_theses = []

for repo in REPOS:
    name, url = repo["name"], repo["url"]
    print(f"\nHarvesting: {name} ({url})")
    
    list_url = f"{url}?verb=ListRecords&metadataPrefix=oai_dc"
    try:
        r = requests.get(list_url, headers=headers, verify=False, timeout=15)
        print(f"  Status: {r.status_code}")
        if r.status_code == 200:
            root = ET.fromstring(r.content)
            records = root.findall(".//{http://www.openarchives.org/OAI/2.0/}record")
            print(f"  Batch Records Returned: {len(records)}")
            
            nursing_count = 0
            for rec in records:
                titles = [e.text for e in rec.findall(".//{http://purl.org/dc/elements/1.1/}title") if e.text]
                creators = [e.text for e in rec.findall(".//{http://purl.org/dc/elements/1.1/}creator") if e.text]
                dates = [e.text for e in rec.findall(".//{http://purl.org/dc/elements/1.1/}date") if e.text]
                desc = [e.text for e in rec.findall(".//{http://purl.org/dc/elements/1.1/}description") if e.text]
                
                blob = " ".join(titles + desc).lower()
                if any(w in blob for w in ["midwif", "nursing", "dnp", "msn", "bsn"]):
                    nursing_count += 1
                    author = creators[0] if creators else "Unknown"
                    date_val = dates[0] if dates else ""
                    year_match = re.search(r"\b(19\d{2}|20[0-2]\d)\b", date_val)
                    grad_year = int(year_match.group(1)) if year_match else None
                    
                    all_harvested_theses.append({
                        "repo": name,
                        "author": author,
                        "title": titles[0] if titles else "",
                        "date_str": date_val,
                        "grad_year": grad_year
                    })
            print(f"  Nursing/Midwifery dissertations in batch: {nursing_count}")
    except Exception as e:
        print(f"  Error harvesting {name}: {e}")

print(f"\nTotal Harvested Dissertations/Theses: {len(all_harvested_theses)}")
for item in all_harvested_theses[:10]:
    print(f"  Repo: {item['repo']} | Author: {item['author']} | Grad Year: {item['grad_year']} | Title: {item['title'][:50]}...")
