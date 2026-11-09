"""Saboteur tests for hhs_opendata_csv_pipeline.py.

This module is the single, shared download/verify/extract/load pipeline
behind every opendata.hhs.gov single-CSV-zip dataset this repo pulls
(download_medicaid_provider_enrollment_segments.py,
download_medicaid_provider_spending.py). Each test either (a) feeds the
loader a deliberately corrupted or adversarial input and asserts it fails
LOUDLY rather than silently producing a wrong result, or (b) mutates a piece
of the pipeline's own logic and asserts some other check would have caught
it. No network access and no external volume required -- every HTTP response
and "blob" is a local fixture.
"""
import hashlib
import os
import zipfile

import pytest

import hhs_opendata_csv_pipeline as pipeline


def _sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def _make_zip(tmp_path, csv_members, name="data.zip"):
    """csv_members: dict of {filename: content_str}. Returns the zip path."""
    path = tmp_path / name
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for fname, content in csv_members.items():
            zf.writestr(fname, content)
    return str(path)


class _FakeResponse:
    """Minimal stand-in for the object urllib.request.urlopen() returns."""
    def __init__(self, body=b"", headers=None):
        self._body = body
        self._pos = 0
        self.headers = headers or {}

    def read(self, n=-1):
        if n is None or n < 0:
            chunk, self._pos = self._body[self._pos:], len(self._body)
        else:
            chunk = self._body[self._pos:self._pos + n]
            self._pos += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


# -- 1. A corrupted-in-transit OR truncated transfer must abort, not --------
#       silently accept bytes that don't match what the server promised ----

def test_download_rejects_corrupted_or_truncated_transfer(tmp_path):
    real_body = b"npi,state\n1234567890,CO\n"
    real_sha = _sha256_bytes(real_body)
    corrupted_body = b"npi,state\n0000000000,ZZ\n"  # same length, different bytes
    truncated_body = b"npi,state\n123"               # server claimed more than this

    def make_opener(body):
        return lambda req: _FakeResponse(body)

    with pytest.raises(pipeline.DownloadVerificationError, match="sha256"):
        pipeline.download_with_sha256("http://example/data.zip", str(tmp_path / "a.zip"),
                                       expected_sha256=real_sha,
                                       expected_size=len(corrupted_body),
                                       opener=make_opener(corrupted_body))

    with pytest.raises(pipeline.DownloadVerificationError, match="Content-Length"):
        pipeline.download_with_sha256("http://example/data.zip", str(tmp_path / "b.zip"),
                                       expected_sha256=_sha256_bytes(truncated_body),
                                       expected_size=10_000,
                                       opener=make_opener(truncated_body))


# -- 2. Verification reads the bytes actually written to disk, not the ------
#       in-flight stream -- catches a mutation that trusts size alone ------

def test_download_verifies_the_file_it_actually_wrote(tmp_path):
    body = b"npi,state\n1234567890,CO\n"

    def opener(req):
        return _FakeResponse(body)

    dest = str(tmp_path / "out.zip")
    result = pipeline.download_with_sha256("http://example/data.zip", dest,
                                            expected_sha256=_sha256_bytes(body),
                                            expected_size=len(body),
                                            opener=opener)
    # The file on disk must independently hash to the same value the
    # function reported -- i.e. sha256_file(dest) is a real, re-derivable
    # fact about dest, not just an echo of what download_with_sha256 claims.
    assert pipeline.sha256_file(dest) == result["sha256"] == _sha256_bytes(body)


# -- 3. A server response with no x-ms-meta-sha256 must not be reported -----
#       as verified -- fetch_blob_metadata must say None, not fabricate -----

def test_metadata_missing_sha256_header_reports_none_not_blank_string():
    def opener(req):
        return _FakeResponse(b"", headers={"Content-Length": "42"})

    meta = pipeline.fetch_blob_metadata("http://example/data.zip", opener=opener)
    assert meta["sha256"] is None
    assert meta["content_length"] == 42


# -- 4. An HTML error page served with a .zip name must not be treated as ---
#       a valid archive ---------------------------------------------------

def test_extract_rejects_non_zip_content(tmp_path):
    fake_zip = tmp_path / "data.zip"
    fake_zip.write_text("<html><body>404 Not Found</body></html>")
    with pytest.raises(pipeline.ZipContentError, match="not a valid zip"):
        pipeline.extract_single_csv(str(fake_zip), str(tmp_path / "out"))


# -- 5. A zip with zero CSV members must be rejected, not silently produce --
#       "no file extracted" and continue -----------------------------------

def test_extract_rejects_zip_with_no_csv(tmp_path):
    zpath = _make_zip(tmp_path, {"readme.txt": "not a csv"})
    with pytest.raises(pipeline.ZipContentError, match="found 0"):
        pipeline.extract_single_csv(zpath, str(tmp_path / "out"))


# -- 6. A zip with two CSV members must be rejected, not silently pick one --

def test_extract_rejects_zip_with_multiple_csvs(tmp_path):
    zpath = _make_zip(tmp_path, {"a.csv": "x\n1\n", "b.csv": "y\n2\n"})
    with pytest.raises(pipeline.ZipContentError, match="found 2"):
        pipeline.extract_single_csv(zpath, str(tmp_path / "out"))


# -- 7. An empty-but-well-formed CSV load must be treated as a failure, -----
#       never a successful "0 rows" load -----------------------------------

def test_load_rejects_zero_row_csv(tmp_path):
    db_path = str(tmp_path / "test.duckdb")
    csv_path = tmp_path / "empty.csv"
    csv_path.write_text("npi,state,enrollment_status\n")  # header only
    with pytest.raises(RuntimeError, match="zero rows"):
        pipeline.load_csv_to_duckdb(str(csv_path), db_path, table_name="t")


# -- 8. NPI-shaped values that look numeric (leading zeros, literal --------
#       "0000000000") must survive the load unchanged -- a type-inferring --
#       mutation (dropping all_varchar=true) would corrupt exactly this ----

def test_load_preserves_leading_zero_and_all_zero_npi(tmp_path):
    db_path = str(tmp_path / "test.duckdb")
    csv_path = tmp_path / "npis.csv"
    csv_path.write_text("npi,state\n0123456789,CO\n0000000000,ZZ\n")
    n = pipeline.load_csv_to_duckdb(str(csv_path), db_path, table_name="t")
    assert n == 2
    out = pipeline.run_duckdb_sql(db_path, "SELECT npi FROM t ORDER BY state;")
    assert "0123456789" in out
    assert "0000000000" in out


# -- 9. Open-ended / sentinel dates (9999-12-31, 1900-01-01) must round- ---
#       trip as literal text, not be nulled out or raise a date-range -----
#       parse error -------------------------------------------------------

def test_load_preserves_sentinel_dates_as_literal_text(tmp_path):
    db_path = str(tmp_path / "test.duckdb")
    csv_path = tmp_path / "segs.csv"
    csv_path.write_text(
        "npi,enrollment_start_date,enrollment_end_date\n"
        "1234567890,1900-01-01,9999-12-31\n"
    )
    n = pipeline.load_csv_to_duckdb(str(csv_path), db_path, table_name="t")
    assert n == 1
    out = pipeline.run_duckdb_sql(
        db_path, "SELECT enrollment_start_date, enrollment_end_date FROM t;")
    assert "1900-01-01" in out
    assert "9999-12-31" in out


# -- 10. Re-running against an unchanged cached zip must not skip ----------
#        re-verification -- a stale-but-matching-name file must still be ---
#        hashed fresh, and a cache that silently drifted from the server's -
#        current advertised hash must be redownloaded, never trusted by ---
#        filename alone (covers run_pipeline()'s cache-reuse branch, the ---
#        one place a TOCTOU-style shortcut could hide) ---------------------

def test_run_pipeline_redownloads_when_cached_zip_no_longer_matches_server(tmp_path, monkeypatch):
    work_dir = tmp_path / "work"
    work_dir.mkdir()
    db_path = str(tmp_path / "external" / "out.duckdb")
    zip_filename = "some-dataset.csv.zip"

    stale_body = b"this is stale local content, not what the server has"
    zip_path = work_dir / zip_filename
    zip_path.write_bytes(stale_body)

    fresh_members = {"some-dataset.csv": "npi,state\n1234567890,CO\n"}
    fresh_zip_bytes = tmp_path / "fresh_source.zip"
    with zipfile.ZipFile(fresh_zip_bytes, "w") as zf:
        for fname, content in fresh_members.items():
            zf.writestr(fname, content)
    fresh_bytes = fresh_zip_bytes.read_bytes()
    fresh_sha = _sha256_bytes(fresh_bytes)

    def fake_fetch_blob_metadata(url, opener=None):
        return {"sha256": fresh_sha, "content_length": len(fresh_bytes)}

    def fake_download_with_sha256(url, dest_path, expected_sha256=None,
                                   expected_size=None, opener=None, chunk_size=None):
        with open(dest_path, "wb") as fh:
            fh.write(fresh_bytes)
        actual = pipeline.sha256_file(dest_path)
        assert actual == expected_sha256  # the real check still ran
        return {"sha256": actual, "size": len(fresh_bytes)}

    monkeypatch.setattr(pipeline, "fetch_blob_metadata", fake_fetch_blob_metadata)
    monkeypatch.setattr(pipeline, "download_with_sha256", fake_download_with_sha256)

    result = pipeline.run_pipeline(
        blob_base="http://example/datasets/some-dataset", version_date="2026-01-01",
        zip_filename=zip_filename, table_name="t",
        work_dir=str(work_dir), db_path=db_path)

    assert result["zip_sha256"] == fresh_sha
    assert result["row_count"] == 1
    # The stale local bytes must actually have been replaced on disk, not
    # merely re-verified-and-ignored.
    assert zip_path.read_bytes() == fresh_bytes


# -- 11. zip_member_sizes() reads sizes from the central directory alone --
#        (no extraction) and reports BOTH compressed and uncompressed -----
#        sizes -- a mutation that reports only one would silently defeat --
#        the headroom check in run_pipeline() -----------------------------

def test_zip_member_sizes_reports_compressed_and_uncompressed(tmp_path):
    content = "npi,state\n" + ("1234567890,CO\n" * 1000)  # compresses well
    zpath = _make_zip(tmp_path, {"data.csv": content})
    sizes = pipeline.zip_member_sizes(zpath)
    assert list(sizes.keys()) == ["data.csv"]
    csize, usize = sizes["data.csv"]
    assert usize == len(content.encode())
    assert 0 < csize < usize  # genuinely compressed, and both numbers are real


# -- 12. run_pipeline() refuses to extract when the archive's OWN declared --
#        uncompressed size would not fit in the destination's free space, --
#        rather than running unzip and filling the disk ---------------------

def test_run_pipeline_aborts_before_extraction_when_uncompressed_size_exceeds_free_space(
        tmp_path, monkeypatch):
    work_dir = tmp_path / "work"
    work_dir.mkdir()
    db_path = str(tmp_path / "external" / "out.duckdb")
    zip_filename = "huge-dataset.csv.zip"

    # A real, valid, tiny zip -- but the headroom check must act on the
    # archive's OWN declared uncompressed size, not the zip's own size on
    # disk, so fake disk_usage() to claim almost no free space.
    zpath = _make_zip(work_dir, {"huge-dataset.csv": "npi,state\n1234567890,CO\n"},
                       name=zip_filename)
    body = (work_dir / zip_filename).read_bytes()
    fresh_sha = _sha256_bytes(body)

    def fake_fetch_blob_metadata(url, opener=None):
        return {"sha256": fresh_sha, "content_length": len(body)}

    class _TinyFreeSpace:
        free = 1

    monkeypatch.setattr(pipeline, "fetch_blob_metadata", fake_fetch_blob_metadata)
    monkeypatch.setattr(pipeline.shutil, "disk_usage", lambda path: _TinyFreeSpace())

    with pytest.raises(RuntimeError, match="would not fit"):
        pipeline.run_pipeline(
            blob_base="http://example/datasets/huge-dataset", version_date="2026-01-01",
            zip_filename=zip_filename, table_name="t",
            work_dir=str(work_dir), db_path=db_path)
