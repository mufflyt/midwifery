#!/usr/bin/env python3
# =============================================================================
# OAI-PMH University Repository Harvester for Nurse-Midwifery Dissertations & Theses
# =============================================================================
import requests
import xml.etree.ElementTree as ET
import csv
import re
import time

# Standard OAI-PMH Endpoints for Major Midwifery Universities
OAI_ENDPOINTS = [
    {"name": "Frontier Nursing University (Digital Commons)", "url": "https://digitalcommons.frontier.edu/do/oai/"},
    {"name": "Yale University (EliScholar)", "url": "https://elischolar.library.yale.edu/do/oai/"},
    {"name": "University of Washington (ResearchWorks)", "url": "https://digital.lib.washington.edu/oai/request"},
    {"name": "Columbia University (Academic Commons)", "url": "https://academiccommons.columbia.edu/oai2d"},
    {"name": "UIC Indigo Repository", "url": "https://indigo.uic.edu/oai/request"}
]

headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
}

print("=== Testing OAI-PMH University Repository Harvesters ===")

for repo in OAI_ENDPOINTS:
    rname = repo["name"]
    rurl = repo["url"]
    print(f"\n--- Testing Repository: {rname} ---")
    print(f"Endpoint: {rurl}")
    
    # Verb 1: Identify
    try:
        r_id = requests.get(f"{rurl}?verb=Identify", headers=headers, timeout=10)
        print(f"Identify Status: {r_id.status_code}")
        if r_id.status_code == 200:
            # Parse repository name
            root = ET.fromstring(r_id.content)
            repo_title = root.find(".//{http://www.openarchives.org/OAI/2.0/}repositoryName")
            if repo_title is not None:
                print(f"Repository Name: {repo_title.text}")
                
        # Verb 2: ListRecords for Dublin Core metadata
        list_url = f"{rurl}?verb=ListRecords&metadataPrefix=oai_dc"
        r_list = requests.get(list_url, headers=headers, timeout=15)
        print(f"ListRecords Status: {r_list.status_code}")
        
        if r_list.status_code == 200:
            root = ET.fromstring(r_list.content)
            # Find all records
            records = root.findall(".//{http://www.openarchives.org/OAI/2.0/}record")
            print(f"Fetched {len(records)} records in first OAI-PMH batch.")
            
            midwifery_matches = []
            for rec in records:
                # Extract creator (author), title, date, subject
                titles = [e.text for e in rec.findall(".//{http://purl.org/dc/elements/1.1/}title") if e.text]
                creators = [e.text for e in rec.findall(".//{http://purl.org/dc/elements/1.1/}creator") if e.text]
                dates = [e.text for e in rec.findall(".//{http://purl.org/dc/elements/1.1/}date") if e.text]
                subjects = [e.text for e in rec.findall(".//{http://purl.org/dc/elements/1.1/}subject") if e.text]
                
                full_text = " ".join(titles + subjects).lower()
                if "midwi" in full_text or "nurse-midwi" in full_text or "dnp" in full_text or "nursing" in full_text:
                    midwifery_matches.append({
                        "creator": creators,
                        "title": titles[0] if titles else "",
                        "date": dates[0] if dates else ""
                    })
                    
            print(f"Found {len(midwifery_matches)} nursing/midwifery dissertation matches in batch.")
            for m in midwifery_matches[:3]:
                print(f"  Author: {m['creator']} | Date: {m['date']} | Title: {m['title'][:60]}...")
                
    except Exception as e:
        print(f"Error testing {rname}: {e}")
    time.sleep(1)

print("\n=== Done OAI-PMH Test ===")
