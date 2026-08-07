# midwifery

Scraper for the [AMCB certification directory](https://ams.amcbmidwife.org/amcbssa/f?p=AMCBSSA:17800)
(American Midwifery Certification Board public primary-source verification listing).

## Usage

    python3 scrape.py    # writes midwives.csv

No dependencies beyond the Python standard library.

## How it works

The directory is an Oracle APEX classic report that hard-caps any result set at
500 rows — paging past row 500 returns *"Invalid set of rows requested"*. The
per-discipline `Total : N` line, however, is exact even when the rows are
capped.

The scraper uses that count to recursively partition the search by certification
number until every bucket is under the cap, fetches each bucket in a single
500-row request, and de-duplicates on (certification, certification number).
Certification numbers are either `CNM`-prefixed or bare digits; the search maps
to a SQL `LIKE`, so `_` serves as a length mask to anchor a bare-digit prefix.

Reported totals as of August 2026: 183 Certified Midwives, 22,126 Certified
Nurse-Midwives.

## Output columns

`certification, certification_number, status, certification_date,
expiration_date, last_name, first_name, middle_name, discipline, primary_source`
