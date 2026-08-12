#!/usr/bin/env python3
# =============================================================================
# Harvest nurse-midwifery graduate names from university commencement programs
# =============================================================================
#
# WHY THIS BEATS THE REPOSITORY ROUTE. A commencement program carries the
# inference STRUCTURALLY:
#
#   "Jane Smith appears under Nurse-Midwifery in University X's 2018
#    commencement program"  ->  Jane Smith completed X's nurse-midwifery program
#
# No timing heuristic, no affiliation parsing, and -- decisively -- no
# conflation of initial midwifery education with a later doctorate. The
# repository route could not separate those: 43% of its usable assignments
# turned out to be degrees earned AFTER certification (median gap 7 years), and
# Frontier alone contributed 280 such rows that would otherwise have been
# recorded as "trained at Frontier".
#
# It also reaches the population OAI never will: certificate and MS graduates
# who never deposited a thesis, which is most midwives.
#
# WHAT THIS DOES NOT DO. It does not link to AMCB. Extraction and linkage are
# separate steps so the name list can be audited before anything is matched.
#
# Usage:
#   python3 harvest_commencement_programs.py --discover     # find PDFs
#   python3 harvest_commencement_programs.py                # discover + parse
#   python3 harvest_commencement_programs.py --only Penn
# Output: artifacts/commencement_midwifery_graduates.csv
#         artifacts/commencement_pdf_inventory.csv
# =============================================================================

import argparse
import csv
import io
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

UA = {"User-Agent": "Mozilla/5.0 (compatible; midwifery-workforce-research/1.0; academic use)"}

# Penn writes "Nurse–Midwifery" with an EN DASH, ECU writes "Nurse Midwifery"
# with a space. Any dash-like character and optional whitespace must match, or
# the largest programs are missed for a typographic reason.
DASH = r"[-‐‑‒–—―\s]*"
HEADING_RX = re.compile(rf"^\s*(nurse{DASH}midwifery|midwifery)"
                        rf"(\s*(/|and|&)\s*[\w\s]{{0,40}})?\s*$", re.I)
MID_ANY_RX = re.compile(rf"nurse{DASH}midwif\w*|midwifery", re.I)

# A line that ends a graduate list: the next program heading, or a section title.
# A graduate list ends at the NEXT program heading. The first version missed
# "Nursing Education" at East Carolina, so the parser ran out of the midwifery
# section and captured a heading as if it were a graduate. Any "Nursing <X>"
# specialty heading now terminates the list.
STOP_RX = re.compile(
    r"^\s*(adult|acute|family|pediatric|psychiatric|women'?s health|neonatal|"
    r"nurse practitioner|nurse anesthes|clinical nurse|leadership|informatics|"
    r"public health|doctor of|master of|bachelor of|phd|dnp program|"
    r"school of|college of|department of|award|honor|scholarship|dean|faculty|"
    r"nursing\s+(education|leadership|informatics|science|administration|practice)|"
    r"(education|leadership|informatics|administration)\s*$)",
    re.I)

# Credentials and role words that mark a line as staff, not a graduating student.
ROLE_RX = re.compile(r"\b(director|chair|dean|professor|faculty|advisor|coordinator)\b", re.I)
CRED_RX = re.compile(r"\b(PhD|DNP|EdD|MD|DO|CNM|CRNA|FNP|WHNP|RN|APRN|FACNM|FAAN|MSN|MPH|MBA)\b")

# Plausible personal name: 2-5 capitalised tokens, allowing initials, hyphens,
# apostrophes and accents.
NAME_RX = re.compile(
    r"^[A-ZÀ-ɏ][\w'À-ɏ.-]*"
    r"(?:\s+[A-ZÀ-ɏ][\w'À-ɏ.-]*){1,4}$")


class LinkGrab(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self._href = None
        self._text = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self._href = dict(attrs).get("href")
            self._text = []

    def handle_data(self, d):
        if self._href is not None:
            self._text.append(d)

    def handle_endtag(self, tag):
        if tag == "a" and self._href:
            self.links.append((self._href, " ".join(self._text).strip()))
            self._href, self._text = None, []


def fetch(url, timeout=45, tries=2, binary=False):
    for a in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
            return raw if binary else raw.decode("utf-8", "replace")
        except Exception:
            time.sleep(1.2 * (a + 1))
    return None


def nursing_seed_urls(domain):
    """Pages that plausibly list commencement programs."""
    return [f"https://{domain}{p}" for p in (
        "/commencement", "/graduation", "/convocation", "/about/commencement",
        "/students/commencement", "/academics/commencement", "/news/commencement",
        "/current-students/commencement", "/student-life/commencement", "/")]


COMMENCEMENT_HINT = re.compile(
    r"commencement|graduation|convocation|recognition[-\s]?ceremony|"
    r"graduate[-\s]?recognition|hooding|degree[-\s]?candidates", re.I)


def discover_pdfs(institution, domains, max_pages=12):
    """Crawl a small number of pages per nursing domain, collecting PDF links
    whose URL or anchor text looks like a commencement program."""
    found, seen_pages = [], set()
    for domain in domains:
        queue = nursing_seed_urls(domain)
        while queue and len(seen_pages) < max_pages:
            u = queue.pop(0)
            if u in seen_pages:
                continue
            seen_pages.add(u)
            html = fetch(u, timeout=25)
            if not html:
                continue
            p = LinkGrab()
            try:
                p.feed(html)
            except Exception:
                continue
            for href, text in p.links:
                full = urllib.parse.urljoin(u, href)
                if not full.lower().startswith("http"):
                    continue
                blob = f"{full} {text}"
                if full.lower().split("?")[0].endswith(".pdf") and COMMENCEMENT_HINT.search(blob):
                    found.append({"institution": institution, "url": full,
                                  "link_text": text[:120], "source_page": u})
                elif (COMMENCEMENT_HINT.search(blob) and domain in full
                      and full not in seen_pages and len(queue) < max_pages):
                    queue.append(full)
            time.sleep(0.3)
    # de-duplicate on URL
    uniq, out = set(), []
    for f in found:
        if f["url"] not in uniq:
            uniq.add(f["url"])
            out.append(f)
    return out


def year_of(url, text):
    m = re.search(r"(19|20)\d{2}", f"{url} {text}")
    return int(m.group(0)) if m else None


def parse_pdf(raw):
    try:
        from pypdf import PdfReader
    except ImportError:
        sys.exit("pypdf required: pip install pypdf")
    try:
        rd = PdfReader(io.BytesIO(raw))
        return "\n".join((p.extract_text() or "") for p in rd.pages)
    except Exception:
        return ""


def extract_graduates(text):
    """Names appearing under a Nurse-Midwifery heading.

    A HEADING is a line that is essentially only the program name. Prose that
    merely mentions midwifery is rejected -- Penn's award citation for a
    student ('...applauded for her passion for midwifery...') is a paragraph,
    not a heading, and would otherwise contribute a spurious name list.
    """
    out, lines = [], [l.strip() for l in text.split("\n")]
    for i, line in enumerate(lines):
        if not HEADING_RX.match(line):
            continue
        for l in lines[i + 1: i + 60]:
            if not l:
                continue
            if STOP_RX.match(l) or HEADING_RX.match(l):
                break
            if ROLE_RX.search(l):          # "Track Director—Abigail Howe-Heyman"
                continue
            # Strip footnote markers and trailing credentials before testing.
            cand = re.sub(r"[†‡*†‡§¶\d]+$", "", l).strip()
            cand = re.sub(r",.*$", "", cand).strip()
            if CRED_RX.search(cand):
                continue
            if NAME_RX.match(cand) and 4 <= len(cand) <= 60:
                out.append({"name": cand, "heading": line})
    return out


def registry(only=None):
    rows = []
    with open("artifacts/acme_repository_registry.csv") as fh:
        for r in csv.DictReader(fh):
            rows.append(r)
    out = []
    for r in rows:
        inst = r["institution"]
        if only and only.lower() not in inst.lower():
            continue
        out.append((inst, r.get("state", ""), NURSING_DOMAINS.get(inst, [])))
    return out


# Nursing-school domains for the 50 ACME programs. Commencement programs are
# published by the nursing school, not the institutional repository, so the
# repository host is usually the wrong place to look.
NURSING_DOMAINS = {
    "Baylor University": ["nursing.baylor.edu"],
    "Baystate Medical Center": ["www.baystatehealth.org"],
    "Bethel University": ["www.bethel.edu"],
    "Boston College": ["www.bc.edu"],
    "California State University Fullerton": ["nursing.fullerton.edu"],
    "Case Western Reserve University": ["case.edu"],
    "Columbia University": ["www.nursing.columbia.edu"],
    "East Carolina University": ["nursing.ecu.edu"],
    "Fairfield University": ["www.fairfield.edu"],
    "Frontier Nursing University": ["frontier.edu"],
    "George Washington University": ["nursing.gwu.edu"],
    "Georgetown University": ["nursing.georgetown.edu"],
    "Georgia College and State University": ["www.gcsu.edu"],
    "Louisiana State University Health Sciences Center": ["nursing.lsuhsc.edu"],
    "Loyola University New Orleans": ["www.loyno.edu"],
    "Marquette University": ["www.marquette.edu"],
    "Montana State University": ["www.montana.edu"],
    "New York University": ["nursing.nyu.edu"],
    "Ohio State University": ["nursing.osu.edu"],
    "Oregon Health Sciences University": ["www.ohsu.edu"],
    "Rutgers University": ["nursing.rutgers.edu"],
    "Seattle University": ["www.seattleu.edu"],
    "Shenandoah University": ["www.su.edu"],
    "SUNY Downstate": ["www.downstate.edu"],
    "Stony Brook University": ["www.stonybrook.edu"],
    "Texas Tech University Health Sciences Center": ["www.ttuhsc.edu"],
    "Thomas Jefferson University": ["www.jefferson.edu"],
    "University at Buffalo": ["nursing.buffalo.edu"],
    "University of Alabama at Birmingham": ["www.uab.edu"],
    "University of Arizona": ["www.nursing.arizona.edu"],
    "University of Arkansas for Medical Sciences": ["nursing.uams.edu"],
    "University of California San Francisco": ["nursing.ucsf.edu"],
    "University of Cincinnati": ["nursing.uc.edu"],
    "University of Colorado Anschutz": ["nursing.cuanschutz.edu"],
    "University of Delaware": ["www.udel.edu"],
    "University of Illinois at Chicago": ["nursing.uic.edu"],
    "University of Iowa": ["nursing.uiowa.edu"],
    "University of Kansas": ["nursing.kumc.edu"],
    "University of Michigan": ["nursing.umich.edu"],
    "University of Minnesota": ["nursing.umn.edu"],
    "University of Nevada Las Vegas": ["www.unlv.edu"],
    "University of New Mexico": ["nursing.unm.edu"],
    "University of Pennsylvania": ["www.nursing.upenn.edu"],
    "University of Pittsburgh": ["www.nursing.pitt.edu"],
    "University of South Carolina": ["sc.edu"],
    "University of Tennessee Health Science Center": ["www.uthsc.edu"],
    "University of Utah": ["nursing.utah.edu"],
    "University of Washington": ["nursing.uw.edu"],
    "Vanderbilt University": ["nursing.vanderbilt.edu"],
    "Yale University": ["nursing.yale.edu"],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--discover", action="store_true", help="find PDFs, do not parse")
    ap.add_argument("--only")
    ap.add_argument("--max-pdfs", type=int, default=25, help="per institution")
    a = ap.parse_args()
    os.makedirs("artifacts", exist_ok=True)

    inventory = []
    for inst, state, domains in registry(a.only):
        if not domains:
            continue
        pdfs = discover_pdfs(inst, domains)
        for p in pdfs[: a.max_pdfs]:
            p["state"] = state
            p["year"] = year_of(p["url"], p["link_text"])
            inventory.append(p)
        print(f"  {inst[:40]:42s} pdfs={len(pdfs)}", flush=True)

    with open("artifacts/commencement_pdf_inventory.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["institution", "state", "year", "url",
                                           "link_text", "source_page"])
        w.writeheader()
        w.writerows(inventory)
    print(f"\nPDFs discovered: {len(inventory)} across "
          f"{len({r['institution'] for r in inventory})} institutions")
    if a.discover:
        return

    grads = []
    for rec in inventory:
        raw = fetch(rec["url"], timeout=90, binary=True)
        if not raw or not raw[:5].startswith(b"%PDF"):
            continue
        txt = parse_pdf(raw)
        if not txt or not MID_ANY_RX.search(txt):
            continue
        for g in extract_graduates(txt):
            grads.append({"institution": rec["institution"], "state": rec["state"],
                          "graduation_year": rec["year"], "graduate_name": g["name"],
                          "heading": g["heading"][:60], "source_url": rec["url"]})
        time.sleep(0.4)

    with open("artifacts/commencement_midwifery_graduates.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["institution", "state", "graduation_year",
                                           "graduate_name", "heading", "source_url"])
        w.writeheader()
        w.writerows(grads)
    print(f"midwifery graduates extracted: {len(grads)} across "
          f"{len({g['institution'] for g in grads})} institutions")
    print("written: artifacts/commencement_midwifery_graduates.csv")


if __name__ == "__main__":
    main()
