#!/usr/bin/env python3
import requests

url = "https://data.cms.gov/provider-data/api/1/metastore/schemas/dataset/items"
r = requests.get(url, timeout=15)

if r.status_code == 200:
    items = r.json()
    for item in items:
        title = item.get("title", "")
        if "medicare physician" in title.lower() or "physician and other practitioner" in title.lower():
            print("Title:", title)
            if item.get("distribution"):
                print("Download URL:", item["distribution"][0].get("downloadURL"))
            print("-" * 60)
