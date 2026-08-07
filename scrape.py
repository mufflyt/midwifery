"""Scrape the AMCB public certification directory (ams.amcbmidwife.org page 17800) to CSV.

The report region hard-caps at 500 rows per result set, but the per-discipline
"Total : N" line is exact, so we recursively split the search on certification
number until every bucket is under the cap, then fetch and de-duplicate.
"""
import csv, html, http.cookiejar, re, sys, time, urllib.parse, urllib.request

BASE = "https://ams.amcbmidwife.org/amcbssa/"
CAP = 500
COLS = ["certification", "certification_number", "status", "certification_date",
        "expiration_date", "last_name", "first_name", "middle_name",
        "discipline", "primary_source"]

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
opener.addheaders = [("User-Agent", "Mozilla/5.0")]


def _text(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", fragment))).strip()


class Directory:
    def __init__(self):
        home = opener.open(BASE + "f?p=AMCBSSA:17800", timeout=60).read().decode("utf8", "replace")
        self.session = re.search(r'name="p_instance" value="(\d+)"', home).group(1)
        self.region = re.search(r"apex\.widget\.report\.paginate\('(\d+)'", home).group(1)

    def _open(self, url, body=None):
        for attempt in range(4):
            try:
                return opener.open(url, body, timeout=60).read().decode("utf8", "replace")
            except Exception as exc:                      # transient net / session loss
                print(f"  retry ({exc})", file=sys.stderr)
                time.sleep(2 * (attempt + 1))
                if attempt == 1:
                    self.__init__()
        raise RuntimeError(f"gave up on {url}")

    def search(self, cert, number=""):
        """Apply search items; return the exact total for this result set."""
        vals = ",".join(urllib.parse.quote(v) for v in (cert, number))
        url = (f"{BASE}f?p=500:17800:{self.session}::NO::"
               f"P17800_CERT,P17800_CERT_NUMBER,P17800_SEARCH_FLG:{vals},Y")
        doc = self._open(url)
        return sum(int(n) for n in re.findall(r"Total : (\d+)", doc))

    def rows(self):
        """Fetch up to CAP rows of the current result set."""
        body = urllib.parse.urlencode({
            "p_flow_id": "500", "p_flow_step_id": "17800", "p_instance": self.session,
            "p_request": f"FLOW_PPR_OUTPUT_R{self.region}_pg_R_{self.region}",
            "p_pg_min_row": 1, "p_pg_max_rows": CAP, "p_pg_rows_fetched": CAP,
        }).encode()
        doc = self._open(BASE + "wwv_flow.show", body)
        out = []
        for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", doc, re.S):
            cells = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if len(cells) == len(COLS):
                out.append(dict(zip(COLS, map(_text, cells))))
        return out


def buckets(cert):
    """Search patterns partitioning every certification number for a discipline.

    Numbers are either CNM-prefixed or bare digits; '_' reaches the underlying
    SQL LIKE, so a length mask anchors a bare-digit prefix.
    """
    yield from (f"{cert}{d}" for d in "0123456789")
    for length in range(3, 8):
        yield from (d + "_" * (length - 1) for d in "0123456789")


def refine(pattern):
    """Split a too-large pattern by inserting another leading digit."""
    if pattern.endswith("_"):
        stem = pattern.rstrip("_")
        return [stem + d + "_" * (len(pattern) - len(stem) - 1) for d in "0123456789"]
    return [pattern + d for d in "0123456789"]


def collect(site, cert, records):
    pending, done = list(buckets(cert)), 0
    while pending:
        pattern = pending.pop(0)
        total = site.search(cert, pattern)
        done += 1
        if total == 0:
            continue
        if total > CAP:
            children = refine(pattern)
            if len(children[0]) > 12:
                print(f"  !! cannot split {pattern} ({total} rows)", file=sys.stderr)
                continue
            pending.extend(children)
            continue
        for row in site.rows():
            records.setdefault((row["certification"], row["certification_number"]), row)
        print(f"  {cert} {pattern:<10} {total:>4} rows  "
              f"(unique so far {len(records)}, {len(pending)} queries queued)",
              file=sys.stderr)
        time.sleep(0.1)
    return done


def main():
    site = Directory()
    records = {}
    for cert in ("CM", "CNM"):
        expected = site.search(cert)
        print(f"{cert}: {expected} records reported", file=sys.stderr)
        before = len(records)
        collect(site, cert, records)
        print(f"{cert}: collected {len(records) - before} / {expected}", file=sys.stderr)

    rows = sorted(records.values(), key=lambda r: (r["last_name"], r["first_name"]))
    with open("midwives.csv", "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=COLS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows to midwives.csv", file=sys.stderr)


main()
