#!/usr/bin/env python3
import requests
import json

headers = {"User-Agent": "Mozilla/5.0", "Accept": "application/json"}
catalog_url = "https://data.cms.gov/provider-data/api/1/metastore/schemas/dataset/items"

r = requests.get(catalog_url, headers=headers, timeout=15)
if r.status_code == 200:
    items = r.json()
    for item in items:
        title = item.get("title", "")
        if "national downloadable file" in title.lower() or "doctors and clinicians" in title.lower():
            print("Title:", title)
            print("ID:", item.get("identifier"))
            if item.get("distribution"):
                print("Download URL:", item["distribution"][0].get("downloadURL"))
            print("-" * 60)
