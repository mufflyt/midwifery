#!/usr/bin/env python3
# =============================================================================
# Discover the institutional repository for each ACME-accredited program
# =============================================================================
#
# THE SAMPLING FRAME IS THE ACCREDITOR, NOT THE INTERNET. Earlier attempts
# searched for "midwifery repositories" and found almost nothing: of 306 records
# harvested from 12 hand-guessed endpoints, only 6 were degree works. The
# problem was the unit of discovery. There is usually no midwifery collection --
# DNP projects are deposited in a university-wide "DNP Projects", "Doctoral
# Projects", "ETD" or "Capstones" collection, and the specialty is not in the
# Dublin Core metadata at all.
#
# Seattle University is the proof: its generic "Doctor of Nursing Practice
# Projects" set holds 209 authors, of which only 7 mention midwifery in
# metadata -- yet 24 of those authors match the AMCB roster. A specialty filter
# discards 97% of the collection and 19 of the 24 real matches.
#
# So the frame is ACME's 51 accredited programs (fetched 2026-08-10). For each:
#
#   ACME program -> university -> repository -> DNP/ETD collection -> authors
#
# and the midwifery keywords become CORROBORATING fields, never inclusion
# requirements.
#
# Usage:
#   python3 discover_acme_repositories.py            # probe and write registry
#   python3 discover_acme_repositories.py --only Baylor
# Output: artifacts/acme_repository_registry.csv
# =============================================================================

import argparse
import concurrent.futures as cf
import csv
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

OAI = "{http://www.openarchives.org/OAI/2.0/}"
UA = {"User-Agent": "midwifery-workforce-research/1.0 (academic use)"}

# ACME-accredited midwifery education programs, https://theacme.org, 2026-08-10.
# (institution, state, degrees, repository host candidates)
ACME = [
    ("Baylor University", "TX", "BS-DNP, post-MS CNM DNP", ["baylor-ir.tdl.org", "digitalcommons.baylor.edu"]),
    ("Baystate Medical Center", "MA", "Certificate, PGC",
     ["scholarlycommons.libraryinfo.bhs.org"]),
    ("Bethel University", "MN", "MS", ["spark.bethel.edu"]),
    ("Boston College", "MA", "MS", ["dlib.bc.edu", "open-bc.primo.exlibrisgroup.com"]),
    ("California State University Fullerton", "CA", "MSN", ["scholarworks.calstate.edu"]),
    ("Case Western Reserve University", "OH", "MSN, PGC", ["commons.case.edu"]),
    ("Columbia University", "NY", "DNP", ["academiccommons.columbia.edu"]),
    ("East Carolina University", "NC", "MSN, PGC", ["thescholarship.ecu.edu"]),
    ("Fairfield University", "CT", "BSN-DNP", ["digitalcommons.fairfield.edu"]),
    ("Frontier Nursing University", "KY", "MSN, PGC", ["frontier.contentdm.oclc.org"]),
    ("George Washington University", "DC", "MSN", ["scholarspace.library.gwu.edu"]),
    ("Georgetown University", "DC", "MS, BSN-DNP, PGC", ["repository.library.georgetown.edu"]),
    ("Georgia College and State University", "GA", "MSN, PMC", ["kb.gcsu.edu"]),
    ("Louisiana State University Health Sciences Center", "LA", "BSN-DNP", ["digitalcommons.lsuhsc.edu"]),
    ("Loyola University New Orleans", "LA", "MSN, PGC", ["scholarworks.loyno.edu"]),
    ("Marquette University", "WI", "MSN, PGC", ["epublications.marquette.edu"]),
    ("Montana State University", "MT", "DNP", ["scholarworks.montana.edu"]),
    ("New York University", "NY", "MS, PGC", ["archive.nyu.edu"]),
    ("Ohio State University", "OH", "MS, DNP, PGC", ["kb.osu.edu"]),
    ("Oregon Health Sciences University", "OR", "DNP", ["digitalcommons.ohsu.edu", "scholararchive.ohsu.edu"]),
    ("Rutgers University", "NJ", "DNP, PGC, MSN", ["rucore.libraries.rutgers.edu", "soar.rutgers.edu"]),
    ("Seattle University", "WA", "DNP, PGC", ["scholarworks.seattleu.edu"]),
    ("Shenandoah University", "VA", "MSN, PGC", ["scholarworks.su.edu"]),
    ("SUNY Downstate", "NY", "MS, PGC", ["soar.suny.edu"]),
    ("Stony Brook University", "NY", "DNP, MS, PGC", ["commons.library.stonybrook.edu"]),
    ("Texas Tech University Health Sciences Center", "TX", "MSN, PGC", ["ttu-ir.tdl.org"]),
    ("Thomas Jefferson University", "PA", "MS, PGC", ["jdc.jefferson.edu"]),
    ("University at Buffalo", "NY", "DNP", ["ubir.buffalo.edu"]),
    ("University of Alabama at Birmingham", "AL", "MSN", ["digitalcommons.library.uab.edu"]),
    ("University of Arizona", "AZ", "PGC, DNP, MS", ["repository.arizona.edu"]),
    ("University of Arkansas for Medical Sciences", "AR", "MNSc", ["scholarworks.uams.edu"]),
    ("University of California San Francisco", "CA", "DNP", ["escholarship.org"]),
    ("University of Cincinnati", "OH", "MSN", ["scholar.uc.edu"]),
    ("University of Colorado Anschutz", "CO", "MS, PGC, DNP", ["digitalcollections.cuanschutz.edu"]),
    ("University of Delaware", "DE", "MSN, PMC", ["udspace.udel.edu"]),
    ("University of Illinois at Chicago", "IL", "DNP, PGC", ["indigo.uic.edu"]),
    ("University of Iowa", "IA", "Post-Bacc Certificate", ["iro.uiowa.edu", "ir.uiowa.edu"]),
    ("University of Kansas", "KS", "DNP, PGC", ["kuscholarworks.ku.edu"]),
    ("University of Michigan", "MI", "MSN, DNP, PGC", ["deepblue.lib.umich.edu"]),
    ("University of Minnesota", "MN", "DNP, PGC", ["conservancy.umn.edu"]),
    ("University of Nevada Las Vegas", "NV", "MSN", ["digitalscholarship.unlv.edu"]),
    ("University of New Mexico", "NM", "PGC, DNP", ["digitalrepository.unm.edu"]),
    ("University of Pennsylvania", "PA", "MSN", ["repository.upenn.edu"]),
    ("University of Pittsburgh", "PA", "DNP", ["d-scholarship.pitt.edu"]),  # EPrints
    ("University of South Carolina", "SC", "DNP, MSN, PGC", ["scholarcommons.sc.edu"]),
    ("University of Tennessee Health Science Center", "TN", "DNP", ["dc.uthsc.edu"]),
    ("University of Utah", "UT", "DNP, PGC", ["collections.lib.utah.edu"]),
    ("University of Washington", "WA", "DNP, PGC", ["digital.lib.washington.edu"]),
    ("Vanderbilt University", "TN", "DNP, MSN, PGC", ["ir.vanderbilt.edu"]),
    ("Yale University", "CT", "MSN", ["elischolar.library.yale.edu"]),
]

# OAI endpoint shapes, by platform.
PATHS = [
    ("/do/oai/", "bepress"),            # Digital Commons
    ("/catalog/oai", "hyrax_eprints"),  # Samvera/Hyrax and some EPrints sites
    ("/oai/request", "dspace6"),
    ("/server/oai/request", "dspace7"),
    ("/oai", "generic"),
    ("/oai2", "generic"),
    ("/dspace-oai/request", "dspace"),
]

# Collections worth harvesting. Deliberately NOT midwifery-specific: the whole
# point is that specialty is absent from repository metadata.
DEGREE_SET_RX = re.compile(
    r"\bdnp\b|doctor of nursing|nursing.*(thes|dissert|etd|project|capstone)"
    r"|(thes|dissert|etd|capstone|scholarly project|doctoral project).*nurs"
    r"|college of nursing|school of nursing|nursing", re.I)
# "nurs" also matches NURSERY: Minnesota's set list contains "Minnesota
# Nurserymens Newsletter" and "Seed and Nursery Catalog Books". Excluded so a
# horticulture collection is never harvested as nursing scholarship.
NOT_NURSING_RX = re.compile(r"nursery|nurserymen|seed and nursery|horticultur", re.I)


def get(url, timeout=25, tries=2):
    # Retry once: a single-shot probe under 10-way concurrency produced a false
    # "not_found" for Frontier, whose API answers fine on its own. A discovery
    # sweep that reports a live repository as missing is worse than a slow one.
    for _ in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
                return r.read().decode("utf-8", "replace")
        except Exception:
            continue
    return None


def probe_school(row):
    inst, state, degrees, hosts = row
    for host in hosts:
        if "contentdm" in host:
            body = get(f"https://{host}/digital/bl/dmwebservices/index.php?q=dmGetCollectionList/json")
            if body:
                try:
                    cols = json.loads(body)
                    return dict(institution=inst, state=state, degrees=degrees,
                                platform="contentdm", base=f"https://{host}",
                                endpoint=f"https://{host}/digital/bl/dmwebservices",
                                n_candidate_sets=len(cols), status="live")
                except json.JSONDecodeError:
                    pass
            continue
        for path, platform in PATHS:
            base = f"https://{host}{path}"
            body = get(base + ("&" if "?" in base else "?") + "verb=Identify")
            if not body or "<repositoryName" not in body:
                continue
            # PAGE THROUGH ListSets. The first version issued ONE request and
            # took whatever came back -- 100 sets. Minnesota publishes 2,488 and
            # Ohio State 3,052, so a single page saw 3-4% of each repository and
            # reported "no nursing collections". Ohio State's "Doctor of Nursing
            # Practice Final Document Projects" (167 records) sat past page 30.
            # Eight institutions were written off on that evidence.
            sets, token, pages = [], None, 0
            while pages < 60:
                q = base + ("&" if "?" in base else "?") + urllib.parse.urlencode(
                    {"verb": "ListSets"} if not token
                    else {"verb": "ListSets", "resumptionToken": token})
                sx = get(q)
                if not sx:
                    break
                try:
                    root = ET.fromstring(sx)
                except ET.ParseError:
                    break
                if root.find(f".//{OAI}error") is not None:
                    break
                for st in root.iter(f"{OAI}set"):
                    spec = st.findtext(f"{OAI}setSpec") or ""
                    name = st.findtext(f"{OAI}setName") or ""
                    blob = f"{name} {spec}"
                    if DEGREE_SET_RX.search(blob) and not NOT_NURSING_RX.search(blob):
                        sets.append(f"{spec}||{name}")
                rt = root.find(f".//{OAI}resumptionToken")
                token = rt.text if rt is not None and rt.text else None
                pages += 1
                if not token:
                    break
            return dict(institution=inst, state=state, degrees=degrees,
                        platform=platform, base=base, endpoint=base,
                        n_candidate_sets=len(sets), status="live",
                        candidate_sets=";".join(sets[:40]))
    return dict(institution=inst, state=state, degrees=degrees, platform="",
                base="", endpoint="", n_candidate_sets=0, status="not_found",
                candidate_sets="")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--out", default="artifacts/acme_repository_registry.csv")
    a = ap.parse_args()
    rows = [r for r in ACME if not a.only or a.only.lower() in r[0].lower()]
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with cf.ThreadPoolExecutor(max_workers=10) as ex:
        res = list(ex.map(probe_school, rows))
    cols = ["institution", "state", "degrees", "platform", "base", "endpoint",
            "n_candidate_sets", "status", "candidate_sets"]
    for r in res:
        r.setdefault("candidate_sets", "")
    with open(a.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(res)
    live = [r for r in res if r["status"] == "live"]
    withsets = [r for r in live if r["n_candidate_sets"] > 0]
    print(f"ACME programs probed        : {len(res)}")
    print(f"  repository found          : {len(live)}")
    print(f"  with nursing/DNP sets     : {len(withsets)}")
    print(f"  not found                 : {len(res)-len(live)}")
    print(f"\nwritten: {a.out}\n")
    for r in sorted(live, key=lambda x: -x["n_candidate_sets"])[:18]:
        print(f"  {r['institution'][:38]:40s} {r['platform']:9s} sets={r['n_candidate_sets']:3d}")
    missing = [r["institution"] for r in res if r["status"] != "live"]
    if missing:
        print("\nNOT FOUND (coverage gap, retained in the registry):")
        for m in missing:
            print("   -", m)


if __name__ == "__main__":
    main()
