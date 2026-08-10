#!/usr/bin/env python3
import requests
import re
import json

headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9"
}

url = "https://doctor.webmd.com/provider/michele-ankrim-4d7a8e0f-90e8-466d-8c46-f9479b185675-overview"
print("Fetching WebMD Profile:", url)

r = requests.get(url, headers=headers, verify=False)
print("Status Code:", r.status_code)

if r.status_code == 200:
    text = r.text
    # Search for JSON state or JSON-LD
    json_ld = re.findall(r'<script type="application/ld\+json">(.*?)</script>', text, re.S)
    print(f"Found {len(json_ld)} JSON-LD blocks.")
    for j in json_ld:
        print("--- JSON-LD ---")
        print(j[:500])
        
    # Search for experience/education text
    exp = re.findall(r"(\d{1,2}\+?\s*years?\s*(?:in\s*)?practice|experience)", text, re.I)
    print("Experience matches:", exp)
    
    grad = re.findall(r"(graduat\w*\s*(?:in\s*)?\d{4}|\b19\d{2}\b|\b20[0-2]\d\b)", text, re.I)
    print("Graduation/Year matches:", grad[:10])
