"""Put the repo root on sys.path so tests can import the top-level scripts.

The scrapers live at the repo root (scrape.py, fetch_npi_candidates.py) rather
than in a package, so this conftest at the root is what lets `import scrape`
resolve from tests/ regardless of the working directory pytest is invoked from.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
