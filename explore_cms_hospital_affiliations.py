#!/usr/bin/env python3
# =============================================================================
# CMS Doctors & Clinicians Hospital Affiliations API & Harvester
# =============================================================================
import requests
import json
import csv
import time

headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "application/json"
}

# 1. Search CMS Metastore API for Doctors and Clinicians Dataset API endpoint
catalog_url = "https://data.cms.gov/provider-data/api/1/metastore/schemas/dataset/items"
print("Searching CMS Provider Data Catalog Metastore API...")

try:
    r = requests.get(catalog_url, headers=headers, timeout=15)
    print(f"Metastore API Status: {r.status_code}")
    if r.status_code == 200:
        items = r.json()
        print(f"Total Datasets in Provider Catalog: {len(items)}")
        
        target_datasets = []
        for item in items:
            title = item.get("title", "")
            if any(k in title.lower() for k in ["hospital affiliation", "doctors and clinicians", "facility affiliation", "clinician"]):
                target_datasets.append({
                    "identifier": item.get("identifier"),
                    "title": title,
                    "downloadURL": item.get("distribution", [{}])[0].get("downloadURL") if item.get("distribution") else None,
                    "accessURL": item.get("distribution", [{}])[0].get("accessURL") if item.get("distribution") else None
                })
                
        print(f"\nFound {len(target_datasets)} relevant CMS provider datasets:")
        for td in target_datasets:
            print(f"  - Title: {td['title']}")
            print(f"    ID: {td['identifier']}")
            print(f"    Download URL: {td['downloadURL']}\n")
            
except Exception as e:
    print(f"Error querying CMS Metastore: {e}")
