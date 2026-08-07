"""Scrape the AMCB public certification directory (ams.amcbmidwife.org page 17800) to CSV.

The report region hard-caps every result set at 500 rows -- paging past row 500
returns "Invalid set of rows requested" -- but the per-discipline "Total : N"
line is exact even when the rows are capped. So the scraper partitions the
search into buckets that each stay under the cap, fetches each in one request,
and de-duplicates.

Only four search items are honoured by the report: certification, certification
number, last name and first name. Certification number matches by INSTR
(substring, no wildcards), which gives the partition used here:

  * numbers prefixed "CNM"/"CM" -> walk the prefix digit by digit (the prefix
    only ever occurs at the start, so a prefixed pattern is effectively anchored)
  * bare digit numbers -> sweep every 3-digit substring; any number with at
    least three digits contains one. Shorter numbers are picked up by the
    2- and 1-digit sweeps, which run only if the count still falls short.
"""
import csv, html, http.cookiejar, re, sys, threading, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "https://ams.amcbmidwife.org/amcbssa/"
CAP = 500
WORKERS = 6
COLS = ["certification", "certification_number", "status", "certification_date",
        "expiration_date", "last_name", "first_name", "middle_name",
        "discipline", "primary_source"]
# The primary-source cell links to AMCB's paid verification checkout; the customer
# id in that link is the directory's own key for the record, so keep it.
CUST_ID = re.compile(r"p_related_cust_id=(\d+)")


def _text(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", fragment))).strip()


class Session:
    """One APEX session: search items are server-side state, so never share."""

    def __init__(self):
        self.connect()

    def connect(self):
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.opener.addheaders = [("User-Agent", "Mozilla/5.0")]
        home = self._get(BASE + "f?p=AMCBSSA:17800")
        self.instance = re.search(r'name="p_instance" value="(\d+)"', home).group(1)
        self.region = re.search(r"apex\.widget\.report\.paginate\('(\d+)'", home).group(1)

    def _get(self, url, body=None):
        return self.opener.open(url, body, timeout=90).read().decode("utf8", "replace")

    def _request(self, url, body=None):
        for attempt in range(4):
            try:
                return self._get(url, body)
            except Exception as exc:
                print(f"  retry {attempt + 1}: {exc}", file=sys.stderr)
                if attempt:
                    self.connect()
        raise RuntimeError(f"gave up on {url}")

    def search(self, cert, number):
        """Apply the search and return the exact total, cap notwithstanding."""
        vals = ",".join(urllib.parse.quote(v) for v in (cert, number))
        doc = self._request(f"{BASE}f?p=500:17800:{self.instance}::NO::"
                            f"P17800_CERT,P17800_CERT_NUMBER,P17800_SEARCH_FLG:{vals},Y")
        return sum(int(n) for n in re.findall(r"Total : (\d+)", doc))

    def rows(self):
        """Fetch up to CAP rows of the current result set."""
        body = urllib.parse.urlencode({
            "p_flow_id": "500", "p_flow_step_id": "17800", "p_instance": self.instance,
            "p_request": f"FLOW_PPR_OUTPUT_R{self.region}_pg_R_{self.region}",
            "p_pg_min_row": 1, "p_pg_max_rows": CAP, "p_pg_rows_fetched": CAP,
        }).encode()
        doc = self._request(BASE + "wwv_flow.show", body)
        out = []
        for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", doc, re.S):
            cells = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if len(cells) == len(COLS):
                row = dict(zip(COLS, map(_text, cells)))
                found = CUST_ID.search(cells[-1])
                row["customer_id"] = found.group(1) if found else ""
                out.append(row)
        return out


_local = threading.local()


def session():
    if not hasattr(_local, "session"):
        _local.session = Session()
    return _local.session


class Collector:
    def __init__(self, cert, expected):
        self.cert, self.expected = cert, expected
        self.records, self.lock = {}, threading.Lock()

    def run(self, patterns):
        with ThreadPoolExecutor(WORKERS) as pool:
            while patterns:
                deeper = []
                for extra in pool.map(self.bucket, patterns):
                    deeper.extend(extra)
                patterns = deeper
        return len(self.records)

    def bucket(self, pattern):
        site = session()
        total = site.search(self.cert, pattern)
        if total == 0:
            return []
        if total > CAP:
            if len(pattern) > 12:
                print(f"  !! cannot split {pattern} ({total} rows)", file=sys.stderr)
                return []
            return [pattern + d for d in "0123456789"]
        rows = site.rows()
        with self.lock:
            for row in rows:
                self.records[(row["certification"], row["certification_number"])] = row
            got = len(self.records)
        print(f"  {self.cert} {pattern:<12}{total:>4} rows   "
              f"{got}/{self.expected} unique", file=sys.stderr)
        return []


def sweeps(cert):
    """Prefixed-number walk, then bare-digit substring sweeps, widest first."""
    yield [f"{cert}{d}" for d in "0123456789"]
    yield [f"{a}{b}{c}" for a in "0123456789" for b in "0123456789" for c in "0123456789"]
    yield [f"{a}{b}" for a in "0123456789" for b in "0123456789"]
    yield list("0123456789")


def main():
    probe = Session()
    records = {}
    for cert in ("CM", "CNM"):
        expected = probe.search(cert, "")
        print(f"{cert}: {expected} records reported", file=sys.stderr)
        collector = Collector(cert, expected)
        for patterns in sweeps(cert):
            if collector.run(patterns) >= expected:
                break
            print(f"{cert}: {len(collector.records)}/{expected} after sweep; "
                  f"widening", file=sys.stderr)
        got = len(collector.records)
        status = "complete" if got == expected else f"SHORT BY {expected - got}"
        print(f"{cert}: collected {got}/{expected} -- {status}", file=sys.stderr)
        records.update(collector.records)

    rows = sorted(records.values(), key=lambda r: (r["last_name"], r["first_name"]))
    with open("midwives.csv", "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=COLS + ["customer_id"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows to midwives.csv", file=sys.stderr)


main()
