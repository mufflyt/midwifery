#!/usr/bin/env python3
import re
import csv

HTML_FILE = "/Users/tmuffly/.gemini/antigravity/brain/8b54cf89-ea59-406d-b675-3b5a984f2732/.system_generated/steps/883/content.md"

with open(HTML_FILE, "r", encoding="utf-8", errors="ignore") as f:
    text = f.read()

# Match facility name and address block
# Pattern: \n\s*([A-Za-z0-9\s\,\&\.\-\'\(\)]+?)\s*\n\s*Address:\s*\n([^\n]+)\s*\n?([^\n]+)?
pattern = re.compile(r"([A-Za-z0-9\s\,\&\.\-\'\(\)\&]+?)\s*Address:\s*\n([^\n]+)(?:\n([^\n]+))?", re.MULTILINE)

matches = pattern.findall(text)
print(f"Total Matches: {len(matches)}")

bcs = []
for m in matches:
    raw_name = m[0].strip()
    name_lines = [l.strip() for l in raw_name.split("\n") if l.strip()]
    facility_name = name_lines[-1] if name_lines else ""
    
    addr1 = m[1].strip()
    addr2 = m[2].strip() if m[2] else ""
    
    full_addr = f"{addr1} {addr2}".strip()
    
    if len(facility_name) > 3 and "Browse" not in facility_name and "Search" not in facility_name and "@context" not in facility_name:
        bcs.append({
            "facility_name": facility_name,
            "address": full_addr
        })

print(f"Extracted {len(bcs)} clean birth centers.")
for bc in bcs[:15]:
    print("Name:", bc["facility_name"], "| Addr:", bc["address"])
