#!/usr/bin/env python3
import requests
import gzip
import io
import re
import html
import sys

s = requests.Session()
headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"}

print("Connecting to Ohio SOS Voter File Download portal...")
r1 = s.get("https://www6.ohiosos.gov/ords/f?p=VOTERFTP:STWD", headers=headers, verify=False)
raw_text = html.unescape(r1.text)

links = re.findall(r"f\?p=VOTERFTP:DOWNLOAD::FILE::2:P2_PRODUCT_NUMBER:[^\s\"'\>]+", raw_text)
print(f"Found {len(links)} Statewide Voter File download links.")

if not links:
    print("No download links found on APEX page.")
    sys.exit(1)

for idx, link in enumerate(links):
    print(f"  [{idx+1}] https://www6.ohiosos.gov/ords/{link}")

dl_url = "https://www6.ohiosos.gov/ords/" + links[0]
print(f"\nFetching product headers from: {dl_url}")

r2 = s.get(dl_url, headers=headers, verify=False, stream=True)
print("HTTP Response Code:", r2.status_code)
print("Content-Disposition:", r2.headers.get("Content-Disposition"))

raw_gz = io.BytesIO()
count = 0
for chunk in r2.iter_content(chunk_size=65536):
    raw_gz.write(chunk)
    count += len(chunk)
    if count > 500000:
        break

raw_gz.seek(0)
with gzip.open(raw_gz, "rt", encoding="latin-1", errors="ignore") as gz:
    header = gz.readline()
    print("\nHeader columns in Ohio SWVF file:")
    cols = header.strip().split(",")
    for i, col in enumerate(cols):
        print(f"  Col {i:2d}: {col}")
    
    print("\nSample Data Row 1:")
    row1 = gz.readline().strip().split(",")
    for i, (c, val) in enumerate(zip(cols, row1)):
        print(f"  {c}: {val}")
