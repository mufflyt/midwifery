#!/usr/bin/env python3
# =============================================================================
# Harvest DNP thesis / capstone metadata to recover TRAINING INSTITUTION
# =============================================================================
#
# WHY. The DAC carries a midwifery school for only 14.3% of the cohort. A
# student-authored DNP project or capstone names its author and lives in a
# specific institution's repository, so the training institution is STRUCTURAL
# -- it comes from which repository the record was found in, not from parsing a
# free-text affiliation.
#
# WHAT THIS SUPERSEDES, and the three defects that made the first attempts
# return nothing:
#
#   1. WRONG PROTOCOL FOR THE BIGGEST SOURCE. Frontier Nursing University, the
#      largest CNM program in the country, runs CONTENTdm (OCLC), not bepress
#      Digital Commons. Every digitalcommons/bepress URL guess 404'd or failed
#      DNS. Its CONTENTdm JSON API exposes 1,864 DNP projects immediately.
#      This module speaks BOTH protocols.
#
#   2. SWEEPING INSTEAD OF TARGETING. Filtering a bounded page-sweep of a whole
#      repository by keyword finds almost nothing: 8 of 12 OAI endpoints
#      returned zero, and the 288 records that did come back from eScholarship
#      were type=article, mostly the same title repeated once per author.
#      Sets/collections are targeted first; sweeping is the fallback, not the
#      plan.
#
#   3. SILENT METADATA LOSS. findtext(f"{DC}date") looks for a DIRECT child of
#      <metadata>, but Dublin Core elements are nested under <oai_dc:dc>. Date
#      and URL were therefore empty for EVERY OAI record -- 0 of 306 populated
#      -- which reads as "these repositories publish no dates" rather than as a
#      parsing bug. Title and creator escaped only because iter() recurses.
#      Fixed with ".//"; a project year is essential here, since it is what
#      distinguishes two same-named students.
#
#   A DOUBLE-FILTER RULE IS ALSO APPLIED, though it was not the cause of the
#   zero I first attributed it to. Where a set is already midwifery-specific,
#   set membership IS the evidence and no keyword filter is applied to its
#   records; keyword filtering runs only inside broader nursing collections.
#   (The University of New Mexico's "Nurse-Midwifery" set turned out to be
#   genuinely EMPTY -- OAI error noRecordsMatch -- so its zero was real.)
#
# WHAT THIS DOES NOT DO. It harvests and normalises metadata. It does NOT link
# authors to the AMCB roster: Dublin Core gives a bare name with no NPI, ORCID
# or credential. Linking is a separate, reviewable step.
#
# Python stdlib only, per this repo's convention for its Python stages.
#
# Usage:
#   python3 harvest_dnp_theses.py --probe          # which endpoints are alive
#   python3 harvest_dnp_theses.py                  # harvest everything
#   python3 harvest_dnp_theses.py --only Frontier  # one institution
#   python3 harvest_dnp_theses.py --max-pages 40
# Output: artifacts/dnp_theses_metadata.csv
# =============================================================================

import argparse
import csv
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

OAI_NS = "{http://www.openarchives.org/OAI/2.0/}"
DC_NS = "{http://purl.org/dc/elements/1.1/}"
UA = {"User-Agent": "midwifery-workforce-research/1.0 (academic use)"}

# --- classification vocabulary ----------------------------------------------
# TARGETED: the set/collection is midwifery-specific. Membership is sufficient
# evidence; do NOT additionally filter record text.
MIDWIFERY_RX = re.compile(r"midwif|nurse[-\s]?midwi|\bCNM\b|\bCM\b(?!\w)", re.I)
# CANDIDATE: nursing degree-work collections. Midwifery theses frequently live
# in a general "Nursing ETDs" collection, so these are harvested and THEN
# filtered on record text.
NURSING_DEGREE_RX = re.compile(
    r"(nurs\w*).*(etd|thes|dissert|doctor|dnp|capstone|scholarly project)"
    r"|(etd|thes|dissert|doctor|dnp|capstone).*(nurs\w*)", re.I)
DEGREE_WORK_RX = re.compile(
    r"thesis|dissertation|doctoral|\bDNP\b|capstone|scholarly project|ETD", re.I)


def registry():
    """Institutions with ACNM-accredited nurse-midwifery programs, with the
    protocol each repository actually speaks. Endpoints verified 2026-08-10;
    ones that failed Identify are kept with `live: False` so the coverage gap
    stays visible instead of vanishing from the list."""
    return [
        # --- CONTENTdm (OCLC) ---
        {"institution": "Frontier Nursing University", "platform": "contentdm",
         "base": "https://frontier.contentdm.oclc.org", "live": True},
        # --- OAI-PMH: bepress Digital Commons ---
        {"institution": "University of New Mexico", "platform": "oai",
         "base": "https://digitalrepository.unm.edu/do/oai/", "live": True},
        {"institution": "Thomas Jefferson University", "platform": "oai",
         "base": "https://jdc.jefferson.edu/do/oai/", "live": True},
        {"institution": "Marquette University", "platform": "oai",
         "base": "https://epublications.marquette.edu/do/oai/", "live": True},
        {"institution": "University of Kentucky", "platform": "oai",
         "base": "https://uknowledge.uky.edu/do/oai/", "live": True},
        {"institution": "Case Western Reserve University", "platform": "oai",
         "base": "https://commons.case.edu/do/oai/", "live": True},
        {"institution": "Yale University", "platform": "oai",
         "base": "https://elischolar.library.yale.edu/do/oai/", "live": True},
        # --- OAI-PMH: DSpace ---
        {"institution": "University of Michigan", "platform": "oai",
         "base": "https://deepblue.lib.umich.edu/dspace-oai/request", "live": True},
        {"institution": "East Carolina University", "platform": "oai",
         "base": "https://thescholarship.ecu.edu/server/oai/request", "live": True},
        {"institution": "University of Minnesota", "platform": "oai",
         "base": "https://conservancy.umn.edu/server/oai/request", "live": True},
        {"institution": "Columbia University", "platform": "oai",
         "base": "https://academiccommons.columbia.edu/oai", "live": True},
        {"institution": "University of Utah", "platform": "oai",
         "base": "https://collections.lib.utah.edu/oai", "live": True},
        # --- known dead, retained so the gap is auditable ---
        {"institution": "Vanderbilt University", "platform": "oai",
         "base": "https://ir.vanderbilt.edu/oai/request", "live": False},
        {"institution": "Emory University", "platform": "oai",
         "base": "https://etd.library.emory.edu/oai", "live": False},
        {"institution": "Oregon Health & Science University", "platform": "oai",
         "base": "https://digitalcommons.ohsu.edu/do/oai/", "live": False},
        {"institution": "Rutgers University", "platform": "oai",
         "base": "https://rucore.libraries.rutgers.edu/oai/", "live": False},
    ]


def http_get(url, params, timeout=45, tries=3):
    q = url + ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    for attempt in range(tries):
        try:
            req = urllib.request.Request(q, headers=UA)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            # 503 + Retry-After is the documented OAI back-pressure signal.
            if e.code == 503:
                try:
                    time.sleep(min(int(e.headers.get("Retry-After", 5)), 30))
                except ValueError:
                    time.sleep(5)
                continue
            return None
        except Exception:
            time.sleep(1.5 * (attempt + 1))
    return None


# =============================================================================
# OAI-PMH
# =============================================================================
def oai_sets(base, max_pages=10):
    """Return [(spec, name, kind)] where kind is 'midwifery' or 'nursing_degree'."""
    out, token, pages = [], None, 0
    while pages < max_pages:
        params = {"verb": "ListSets"} if not token else \
                 {"verb": "ListSets", "resumptionToken": token}
        body = http_get(base, params)
        if not body:
            break
        try:
            root = ET.fromstring(body)
        except ET.ParseError:
            break
        for s in root.iter(f"{OAI_NS}set"):
            spec = s.findtext(f"{OAI_NS}setSpec") or ""
            name = s.findtext(f"{OAI_NS}setName") or ""
            blob = f"{name} {spec}"
            if MIDWIFERY_RX.search(blob):
                out.append((spec, name, "midwifery"))
            elif NURSING_DEGREE_RX.search(blob):
                out.append((spec, name, "nursing_degree"))
        rt = root.find(f".//{OAI_NS}resumptionToken")
        token = rt.text if rt is not None and rt.text else None
        pages += 1
        if not token:
            break
    return out


def oai_harvest(inst, base, max_pages, sleep=0.4):
    sets = oai_sets(base)
    plans = []
    for spec, name, kind in sets:
        plans.append({"params": {"verb": "ListRecords", "metadataPrefix": "oai_dc",
                                 "set": spec},
                      "set_name": name, "kind": kind})
    if not plans:
        # Fallback sweep. Recorded as such: a keyword-filtered sweep of a large
        # repository is weak evidence of absence, not evidence of absence.
        plans.append({"params": {"verb": "ListRecords", "metadataPrefix": "oai_dc"},
                      "set_name": "(whole repository sweep)", "kind": "sweep"})

    recs, seen = [], set()
    for plan in plans:
        token, pages = None, 0
        while pages < max_pages:
            params = plan["params"] if not token else \
                     {"verb": "ListRecords", "resumptionToken": token}
            body = http_get(base, params)
            if not body:
                break
            try:
                root = ET.fromstring(body)
            except ET.ParseError:
                break
            if root.find(f".//{OAI_NS}error") is not None:
                break
            for rec in root.iter(f"{OAI_NS}record"):
                md = rec.find(f".//{OAI_NS}metadata")
                if md is None:
                    continue
                title = " ".join((t.text or "") for t in md.iter(f"{DC_NS}title")).strip()
                subj = " ".join((t.text or "") for t in md.iter(f"{DC_NS}subject"))
                desc = " ".join((t.text or "")[:400] for t in md.iter(f"{DC_NS}description"))
                typ = " ".join((t.text or "") for t in md.iter(f"{DC_NS}type")).strip()
                blob = " ".join([title, subj, desc, typ, plan["set_name"]])

                # THE FIX. A midwifery-specific set is already the evidence;
                # re-filtering its records on keywords discarded real theses.
                if plan["kind"] != "midwifery" and not MIDWIFERY_RX.search(blob):
                    continue

                ident = rec.findtext(f".//{OAI_NS}identifier") or ""
                for c in md.iter(f"{DC_NS}creator"):
                    nm = (c.text or "").strip()
                    if not nm:
                        continue
                    key = (ident, nm.lower())
                    if key in seen:
                        continue
                    seen.add(key)
                    # findtext MUST use ".//": Dublin Core elements are nested
                    # under <oai_dc:dc>, not direct children of <metadata>. The
                    # first version omitted it and silently produced an empty
                    # date and url for EVERY OAI record -- 0 of 306 populated,
                    # which reads as "the repository has no dates" rather than
                    # as a parsing bug. Title/creator escaped it only because
                    # iter() recurses.
                    recs.append(_row(inst, "oai", plan["set_name"], plan["kind"],
                                     nm, title, md.findtext(f".//{DC_NS}date"), typ,
                                     blob, ident, md.findtext(f".//{DC_NS}identifier")))
            rt = root.find(f".//{OAI_NS}resumptionToken")
            token = rt.text if rt is not None and rt.text else None
            pages += 1
            time.sleep(sleep)
            if not token:
                break
    return recs, sets


# =============================================================================
# CONTENTdm (OCLC)
# =============================================================================
def contentdm_collections(base):
    api = base + "/digital/bl/dmwebservices/index.php?q="
    body = http_get(api + urllib.parse.quote("dmGetCollectionList/json"), {})
    if not body:
        return []
    try:
        cols = json.loads(body)
    except json.JSONDecodeError:
        return []
    out = []
    for c in cols:
        alias = (c.get("alias") or "").lstrip("/")
        name = c.get("name") or ""
        blob = f"{name} {alias}"
        if MIDWIFERY_RX.search(blob):
            out.append((alias, name, "midwifery"))
        elif NURSING_DEGREE_RX.search(blob) or DEGREE_WORK_RX.search(name):
            out.append((alias, name, "nursing_degree"))
        elif re.search(r"student|dnp|project", name, re.I):
            out.append((alias, name, "student_work"))
    return out


def contentdm_harvest(inst, base, page=100, sleep=0.3):
    api = base + "/digital/bl/dmwebservices/index.php?q="
    cols = contentdm_collections(base)
    recs = []
    for alias, name, kind in cols:
        start, total = 1, None
        while True:
            q = f"dmQuery/{alias}/0/title!creato!date!descri/nosort/{page}/{start}/0/json"
            body = http_get(api + urllib.parse.quote(q), {})
            if not body:
                break
            try:
                d = json.loads(body)
            except json.JSONDecodeError:
                break
            total = int(d.get("pager", {}).get("total", 0) or 0)
            got = d.get("records", []) or []
            if not got:
                break
            for r in got:
                nm = (r.get("creato") or "").strip()
                if not nm:
                    continue
                title = (r.get("title") or "").replace("\n", " ").strip()
                blob = f"{title} {r.get('descri','')} {name}"
                if kind != "midwifery" and not MIDWIFERY_RX.search(blob):
                    continue
                url = f"{base}/digital/collection/{alias}/id/{r.get('pointer')}"
                recs.append(_row(inst, "contentdm", name, kind, nm, title,
                                 r.get("date"), "", blob, url, url))
            start += len(got)
            if total and start > total:
                break
            time.sleep(sleep)
    return recs, cols


# =============================================================================
def _split_name(raw):
    """Repositories store either 'Last, First M' or 'First M Last'."""
    raw = re.sub(r"\s+", " ", (raw or "").strip())
    if "," in raw:
        last, _, rest = raw.partition(",")
        return last.strip(), rest.strip()
    parts = raw.split(" ")
    return (parts[-1], " ".join(parts[:-1])) if len(parts) > 1 else (raw, "")


def _row(inst, platform, coll, kind, name, title, date, typ, blob, ident, url):
    last, first = _split_name(name)
    return {
        "training_institution": inst,
        "platform": platform,
        "collection": coll,
        # How the record qualified: membership of a midwifery collection, or a
        # keyword match inside a broader one. Weaker evidence must be visible.
        "evidence": ("collection_is_midwifery" if kind == "midwifery"
                     else f"keyword_match_in_{kind}"),
        "author_raw": name,
        "author_last": last,
        "author_first": first,
        "title": (title or "")[:300],
        "date": (date or "")[:10],
        "type": (typ or "")[:80],
        "is_degree_work": bool(DEGREE_WORK_RX.search(blob or "")),
        "identifier": (ident or "")[:200],
        "url": (url or "")[:250],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--probe", action="store_true", help="test endpoints only")
    ap.add_argument("--only", help="substring of institution name")
    ap.add_argument("--max-pages", type=int,
                    default=int(os.environ.get("OAI_MAX_PAGES", "25")))
    ap.add_argument("--out", default="artifacts/dnp_theses_metadata.csv")
    args = ap.parse_args()

    targets = [r for r in registry() if r["live"]]
    if args.only:
        targets = [r for r in targets if args.only.lower() in r["institution"].lower()]
    if not targets:
        sys.exit("no live endpoints selected")

    if args.probe:
        for r in targets:
            if r["platform"] == "oai":
                ok = http_get(r["base"], {"verb": "Identify"}) is not None
                sets = oai_sets(r["base"]) if ok else []
                print(f"  {'OK ' if ok else 'DEAD'} {r['institution']:38s} "
                      f"sets(midwifery/nursing)={len(sets)}")
            else:
                cols = contentdm_collections(r["base"])
                print(f"  {'OK ' if cols else 'DEAD'} {r['institution']:38s} "
                      f"collections={len(cols)}")
        return

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    allrecs = []
    for r in targets:
        t0 = time.time()
        try:
            if r["platform"] == "contentdm":
                recs, cols = contentdm_harvest(r["institution"], r["base"])
            else:
                recs, cols = oai_harvest(r["institution"], r["base"], args.max_pages)
        except Exception as e:
            recs, cols = [], []
            print(f"  {r['institution']:38s} ERROR {type(e).__name__}: {e}", flush=True)
        allrecs.extend(recs)
        print(f"  {r['institution']:38s} records={len(recs):5d} "
              f"targeted_collections={len(cols):2d} ({time.time()-t0:.0f}s)", flush=True)

    cols = ["training_institution", "platform", "collection", "evidence",
            "author_raw", "author_last", "author_first", "title", "date", "type",
            "is_degree_work", "identifier", "url"]
    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(allrecs)

    strong = sum(1 for r in allrecs if r["evidence"] == "collection_is_midwifery")
    print(f"\nTOTAL records           : {len(allrecs)}")
    print(f"  from a midwifery collection (strong): {strong}")
    print(f"  keyword-matched (weaker)           : {len(allrecs)-strong}")
    print(f"distinct authors        : {len({r['author_raw'].lower() for r in allrecs})}")
    print(f"degree works            : {sum(1 for r in allrecs if r['is_degree_work'])}")
    print(f"written                 : {args.out}")


if __name__ == "__main__":
    main()
