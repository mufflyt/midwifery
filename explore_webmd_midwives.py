#!/usr/bin/env python3
# =============================================================================
# WebMD Directory Provider DOB / Age Explorer
# =============================================================================
import requests
import re
import json

headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
}

# Test querying WebMD Directory search endpoint
url = "https://directory.webmd.com/api/v1/search?query=nurse+midwife"
print("Querying WebMD Directory API:", url)

try:
    r = requests.get(url, headers=headers, timeout=10)
    print("Status code:", r.status_code)
    if r.status_code == 200:
        data = r.json()
        print("Keys:", list(data.keys()))
except Exception as e:
    print("Error:", e)
