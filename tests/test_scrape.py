"""Tests for the AMCB directory scraper's pure parsing logic (scrape.py).

Everything here runs without network access: the parsing functions take raw
HTML fragments, and the one test that exercises Collector.bucket() injects a
fake session so no request is made.
"""
import types

import pytest

import scrape


# --- _text -------------------------------------------------------------------

def test_text_strips_tags_unescapes_and_collapses_whitespace():
    assert scrape._text("<td class='x'>Smith&amp;  Jones</td>") == "Smith& Jones"


def test_text_collapses_newlines_and_tabs_across_nested_tags():
    assert scrape._text("  <b>A</b>\n\t<i>B</i> ") == "A B"


def test_text_of_empty_fragment_is_empty_string():
    assert scrape._text("") == ""
    assert scrape._text("<td></td>") == ""


# --- parse_total -------------------------------------------------------------

def test_parse_total_sums_every_total_line():
    # The report emits one "Total : N" per discipline; the scraper trusts the
    # sum even when the 500-row cap truncates the visible rows.
    doc = "junk Total : 183 more junk Total : 22126 tail"
    assert scrape.parse_total(doc) == 183 + 22126


def test_parse_total_is_zero_when_absent():
    assert scrape.parse_total("no totals here") == 0


# --- parse_rows --------------------------------------------------------------

def _row_html(cells, cust_link=""):
    tds = "".join(f"<td>{c}</td>" for c in cells[:-1])
    tds += f"<td>{cells[-1]}{cust_link}</td>"
    return f"<tr>{tds}</tr>"


def test_parse_rows_reads_a_full_width_row_and_customer_id():
    cells = ["CNM", "CNM12345", "ACTIVE", "2010-01-01", "2030-01-01",
             "Smith", "Jane", "Q", "Nurse-Midwife", "verify"]
    link = "<a href='purchase_product?p_related_cust_id=98765'>Verify</a>"
    doc = "<table>" + _row_html(cells, link) + "</table>"

    rows = scrape.parse_rows(doc)

    assert len(rows) == 1
    row = rows[0]
    assert row["certification"] == "CNM"
    assert row["certification_number"] == "CNM12345"
    assert row["last_name"] == "Smith"
    assert row["customer_id"] == "98765"


def test_parse_rows_leaves_customer_id_blank_when_no_purchase_link():
    cells = ["CM", "123", "INACTIVE", "", "", "Doe", "Amy", "", "Midwife", "-"]
    doc = _row_html(cells)
    (row,) = scrape.parse_rows(doc)
    assert row["customer_id"] == ""


def test_parse_rows_ignores_rows_of_the_wrong_width():
    header = "<tr><th>a</th><th>b</th></tr>"
    short = "<tr><td>only</td><td>two</td></tr>"
    assert scrape.parse_rows(header + short) == []


# --- sweeps ------------------------------------------------------------------

def test_sweeps_yields_prefixed_walk_then_3_2_1_digit_sweeps():
    buckets = list(scrape.sweeps("CNM"))
    assert [len(b) for b in buckets] == [10, 1000, 100, 10]
    # First bucket is the prefixed digit walk, anchored on the credential.
    assert buckets[0] == [f"CNM{d}" for d in "0123456789"]
    # Widest bare-digit sweep first: every 3-digit substring.
    assert "000" in buckets[1] and "999" in buckets[1]


# --- Collector.bucket (session injected, no network) -------------------------

class _FakeSession:
    """Stands in for scrape.Session: canned totals and rows, no I/O."""

    def __init__(self, totals, rows_by_pattern=None):
        self.totals = totals
        self.rows_by_pattern = rows_by_pattern or {}
        self.searched = []

    def search(self, cert, pattern):
        self.searched.append((cert, pattern))
        return self.totals.get(pattern, 0)

    def rows(self):
        # bucket() calls rows() right after a successful under-cap search().
        return self.rows_by_pattern.get(self.searched[-1][1], [])


@pytest.fixture
def fake_session(monkeypatch):
    holder = {}

    def install(session):
        holder["session"] = session
        monkeypatch.setattr(scrape, "session", lambda: session)
        return session

    return install


def test_bucket_empty_total_collects_nothing(fake_session):
    fake_session(_FakeSession(totals={"CNM1": 0}))
    col = scrape.Collector("CNM", expected=100)
    assert col.bucket("CNM1") == []
    assert col.records == {}


def test_bucket_over_cap_splits_into_ten_children(fake_session):
    fake_session(_FakeSession(totals={"CNM1": 999}))
    col = scrape.Collector("CNM", expected=100)
    children = col.bucket("CNM1")
    assert children == [f"CNM1{d}" for d in "0123456789"]
    assert col.records == {}   # nothing collected when splitting


def test_bucket_over_cap_but_unsplittable_gives_up(fake_session):
    long_pattern = "1234567890123"   # len 13 > 12: cannot split further
    fake_session(_FakeSession(totals={long_pattern: 999}))
    col = scrape.Collector("CNM", expected=100)
    assert col.bucket(long_pattern) == []


def test_bucket_under_cap_collects_and_dedups_on_cert_and_number(fake_session):
    rows = [
        {"certification": "CNM", "certification_number": "CNM1"},
        {"certification": "CNM", "certification_number": "CNM1"},   # dup key
        {"certification": "CNM", "certification_number": "CNM2"},
    ]
    fake_session(_FakeSession(totals={"CNM": 3}, rows_by_pattern={"CNM": rows}))
    col = scrape.Collector("CNM", expected=2)
    assert col.bucket("CNM") == []
    assert len(col.records) == 2   # the two distinct (cert, number) keys
