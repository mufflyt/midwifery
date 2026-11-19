#!/usr/bin/env python3
"""Download the current NPPES Deactivated NPI Report (monthly, V.2).

CMS publishes the deactivation report monthly alongside the full-replacement
dissemination file; the filename embeds the release date, so it is discovered
from the NPI Files index page rather than constructed. The report is the
input to check_npi_deactivation.R, which reads it through the
NPI_DEACTIVATION_REPORT environment variable.

Refuses silently-stale files: the downloaded xlsx's own release date is
parsed from its name and reported so an old cache cannot pass for current.

Usage: python3 download_nppes_deactivation.py [--out-dir DIR]
Output: <out-dir>/NPPES Deactivated NPI Report YYYYMMDD.xlsx
"""
import argparse
import os
import re
import sys
import urllib.request
import zipfile

INDEX = "https://download.cms.gov/nppes/NPI_Files.html"
LINK_RE = re.compile(r"(NPPES_Deactivated_NPI_Report_\d{6}_V2\.zip)")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default=os.path.expanduser("~/Documents"))
    args = p.parse_args()

    html = urllib.request.urlopen(INDEX, timeout=60).read().decode("utf-8", "replace")
    links = LINK_RE.findall(html)
    if not links:
        sys.exit("no deactivated-NPI-report link on the CMS index page")
    fname = links[0]
    url = f"https://download.cms.gov/nppes/{fname}"
    zip_path = os.path.join(args.out_dir, fname)
    urllib.request.urlretrieve(url, zip_path)

    with zipfile.ZipFile(zip_path) as z:
        members = [m for m in z.namelist() if m.endswith(".xlsx")]
        if len(members) != 1:
            sys.exit(f"expected one xlsx in {fname}, found {members}")
        z.extract(members[0], args.out_dir)
        out = os.path.join(args.out_dir, members[0])
    os.remove(zip_path)
    release = re.search(r"(\d{8})", members[0]).group(1)
    print(f"downloaded {url} -> {out} (release {release[:4]}-{release[4:6]}-{release[6:]})")
    print(f"use: NPI_DEACTIVATION_REPORT={out!r} Rscript check_npi_deactivation.R")


if __name__ == "__main__":
    main()
