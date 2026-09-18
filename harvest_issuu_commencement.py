#!/usr/bin/env python3
# =============================================================================
# Harvest nurse-midwifery graduate names from Issuu digital commencement publications
# =============================================================================
#
# WHY THIS Pipeline IS ESSENTIAL FOR FRONTIER NURSING UNIVERSITY:
# Frontier Nursing University (FNU) is the largest single nurse-midwifery school
# in the United States (~30-40% of all newly certified CNMs). FNU publishes its
# commencement program books on Issuu rather than direct PDFs on frontier.edu.
#
# This script:
# 1. Fetches Frontier commencement publication manifests from Issuu.
# 2. Streams high-resolution page rendering images (`image.isu.pub`).
# 3. Uses macOS native Vision OCR (`./ocr_local`) to extract full page text.
# 4. Parses ground-truth nurse-midwifery track graduates (`MSN, CNEP` and `PGC, CNEP`).
# 5. Appends ground-truth graduates to artifacts/commencement_midwifery_graduates.csv.
#
# Output: artifacts/commencement_midwifery_graduates.csv
# =============================================================================

import csv
import json
import os
import re
import ssl
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}

ISSUU_PUBLICATIONS = [
    {
        "institution": "Frontier Nursing University",
        "state": "KY",
        "graduation_year": 2025,
        "doc_id": "251205142140-9f92ff9497bac3e7f63ac7effbf66d60",
        "doc_name": "2025_frontier_nursing_university_commencement_prog",
        "page_count": 38,
        "midwifery_pages": range(10, 16),
        "source_url": "https://issuu.com/frontiernursinguniversity/docs/2025_frontier_nursing_university_commencement_prog"
    }
]

NAME_RX = re.compile(r"^[A-ZÀ-ɏ][\w'À-ɏ.-]*(?:\s+[A-ZÀ-ɏ][\w'À-ɏ.-]*){1,3}$")
STOP_WORDS = {"CNEP", "MSN", "PGC", "Page", "Frontier", "University", "Commencement", "Department", "Chair", "Dear", "NURSING", "NURSE", "MIDWIFERY"}


def ensure_ocr_binary():
    binary_path = os.path.join(os.getcwd(), "ocr_local")
    if not os.path.exists(binary_path):
        swift_script = os.path.join(os.getcwd(), "scratch", "ocr_local.swift")
        if os.path.exists(swift_script):
            subprocess.run(["swiftc", swift_script, "-o", binary_path], check=True)
        else:
            sys.exit("ocr_local binary not found and swift script missing.")
    return binary_path


def download_page_image(doc_id, page, out_dir):
    img_path = os.path.join(out_dir, f"page_{page}.jpg")
    if os.path.exists(img_path) and os.path.getsize(img_path) > 0:
        return img_path

    url = f"https://image.isu.pub/{doc_id}/jpg/page_{page}.jpg"
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
            data = resp.read()
            with open(img_path, "wb") as fh:
                fh.write(data)
        return img_path
    except Exception as e:
        print(f"Error downloading page {page}: {e}", file=sys.stderr)
        return None


def ocr_page_image(ocr_binary, img_path):
    txt_path = img_path.replace(".jpg", ".txt")
    if os.path.exists(txt_path) and os.path.getsize(txt_path) > 0:
        with open(txt_path, "r", encoding="utf-8", errors="ignore") as fh:
            return fh.read()

    res = subprocess.run([ocr_binary, img_path], capture_output=True, text=True)
    text = res.stdout or ""
    with open(txt_path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return text


def process_issuu_pub(pub, ocr_binary):
    print(f"\nProcessing Issuu Publication: {pub['institution']} ({pub['graduation_year']})", flush=True)
    out_dir = os.path.join("scratch", f"issuu_{pub['doc_name']}")
    os.makedirs(out_dir, exist_ok=True)

    # 1. Download images in parallel
    print(f"  Downloading {pub['page_count']} page renderings...", flush=True)
    with ThreadPoolExecutor(max_workers=8) as ex:
        futures = [ex.submit(download_page_image, pub["doc_id"], p, out_dir) for p in range(1, pub["page_count"] + 1)]
        img_paths = [f.result() for f in futures if f.result()]

    # 2. Run Vision OCR in parallel
    print("  Running macOS Vision OCR...", flush=True)
    with ThreadPoolExecutor(max_workers=8) as ex:
        futures = [ex.submit(ocr_page_image, ocr_binary, img_path) for img_path in img_paths]
        texts = [f.result() for f in futures]

    # 3. Parse nurse-midwifery track graduates (CNEP credential)
    grads = []
    seen = set()

    for p in pub["midwifery_pages"]:
        txt_path = os.path.join(out_dir, f"page_{p}.txt")
        if not os.path.exists(txt_path):
            continue
        with open(txt_path, "r", encoding="utf-8", errors="ignore") as fh:
            txt = fh.read()

        lines = [l.strip() for l in txt.split("\n") if l.strip()]

        names = []
        details = []

        for l in lines:
            if "CNEP" in l:
                details.append(l)
            elif NAME_RX.match(l) and not any(w in l for w in STOP_WORDS):
                names.append(l)

        # Paired inline matching
        for i, l in enumerate(lines):
            if "CNEP" in l and i > 0:
                cand = re.sub(r"[§¶†‡*]+", "", lines[i - 1]).strip()
                if cand and cand in names:
                    m_state = re.search(r"\b([A-Z]{2})\b\s+(\d{1,2}/\d{1,2}/\d{2,4})", l)
                    st = m_state.group(1) if m_state else pub["state"]
                    deg = "PGC Nurse-Midwifery" if "PGC" in l else "MSN Nurse-Midwifery"
                    key = (cand, st, pub["graduation_year"])
                    if key not in seen:
                        seen.add(key)
                        grads.append({
                            "institution": pub["institution"],
                            "state": st,
                            "graduation_year": pub["graduation_year"],
                            "graduate_name": cand,
                            "heading": deg,
                            "source_url": pub["source_url"]
                        })

        # Sequential fallback for column-separated layouts
        if len(names) == len(details) and len(names) > 0:
            for nm, dt in zip(names, details):
                m_state = re.search(r"\b([A-Z]{2})\b\s+(\d{1,2}/\d{1,2}/\d{2,4})", dt)
                st = m_state.group(1) if m_state else pub["state"]
                deg = "PGC Nurse-Midwifery" if "PGC" in dt else "MSN Nurse-Midwifery"
                key = (nm, st, pub["graduation_year"])
                if key not in seen:
                    seen.add(key)
                    grads.append({
                        "institution": pub["institution"],
                        "state": st,
                        "graduation_year": pub["graduation_year"],
                        "graduate_name": nm,
                        "heading": deg,
                        "source_url": pub["source_url"]
                    })

    print(f"  -> Extracted {len(grads)} ground-truth nurse-midwifery graduates from {pub['institution']}")
    return grads


def main():
    ocr_binary = ensure_ocr_binary()
    all_issuu_grads = []

    for pub in ISSUU_PUBLICATIONS:
        grads = process_issuu_pub(pub, ocr_binary)
        all_issuu_grads.extend(grads)

    # Merge into artifacts/commencement_midwifery_graduates.csv
    csv_path = "artifacts/commencement_midwifery_graduates.csv"
    existing = []
    if os.path.exists(csv_path):
        with open(csv_path, "r", encoding="utf-8") as fh:
            existing = list(csv.DictReader(fh))

    # De-duplicate on (institution, graduation_year, graduate_name)
    merged = []
    seen = set()

    for r in existing + all_issuu_grads:
        key = (r["institution"], str(r["graduation_year"]), r["graduate_name"])
        if key not in seen:
            seen.add(key)
            merged.append(r)

    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["institution", "state", "graduation_year", "graduate_name", "heading", "source_url"])
        w.writeheader()
        w.writerows(merged)

    print(f"\nTotal merged nurse-midwifery graduates in {csv_path}: {len(merged)}")


if __name__ == "__main__":
    main()
