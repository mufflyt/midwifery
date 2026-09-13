#!/usr/bin/env python3
# =============================================================================
# National Certified Nurse-Midwife (CNM) Interactive Leaflet Map Generator
# =============================================================================
# Served live on GitHub Pages, so every word and number on the page is a claim
# made in public. Every count below is computed from the data this script
# loads; none is typed in.
#
# Rebuilt 2026-09-13. The previous version read artifacts/scraped_20_state_
# bons_midwives_master.csv -- a gitignored file whose "board" fields were
# synthesized (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md) -- and its
# page carried typed-in headline figures ("11,920 Active Cohort", "7,470
# Delivery Attenders", "2,611 Hospital Attenders", "221 Birth Centers") beside
# 8,952 markers for 20 states. The delivery badge on 3,465 popups ("Confirmed
# Active Attending Delivery Midwife (CPT 59400/59409/59410)") and the "Active
# CPT Delivery Attenders Only" filter came from a flag that was really "DAC
# primary specialty is CNM"; public Part B has no delivery-code rows for anyone
# (artifacts/medicare_delivery_code_observability.csv). One marker sat at an
# address hand-typed into NPPES fields.
#
# Inputs, all tracked, so the page rebuilds from a fresh clone:
#   artifacts/tracked_roster_active_primary_linked.csv   who, NPPES address,
#       and board licence where WA DOH, Colorado DORA or the Texas BON returned
#       one (build_tracked_roster.R)
#   artifacts/ob_hospitals_geocoded.csv   geocoded obstetric hospitals; a
#       midwife whose NPPES street address IS one is placed on it
#   data/gaz_zcta_2020.zip   Census 2020 ZCTA Gazetteer; everyone else is placed
#       at the internal point of their NPPES ZIP, and the popup says so
# =============================================================================
import csv
import io
import json
import zipfile

ROSTER_FILE = "artifacts/tracked_roster_active_primary_linked.csv"
HOSP_GEO_FILE = "artifacts/ob_hospitals_geocoded.csv"
ZCTA_GAZ_ZIP = "data/gaz_zcta_2020.zip"
OUT_HTML = "docs/cnm_national_leaflet_map.html"

# Fifty states plus DC, to say which the roster does not cover rather than to
# imply it covers them all.
STATES_AND_DC = set("""AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME
MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA
WA WV WI WY""".split())

# The open-data dataset each board value was read from. A link to where the
# value came from, never a deep link built from a number.
BOARD_DATASET_URL = {
    "WA": "https://data.wa.gov/d/qxh8-f4bd",
    "CO": "https://data.colorado.gov/d/7s5z-vewr",
    "TX": "https://data.texas.gov/d/jnzg-cr4w",
}
BOARD_NAME = {"WA": "WA DOH", "CO": "Colorado DORA", "TX": "Texas BON"}
BOARDS_QUERIED = sorted(BOARD_DATASET_URL)

print("=== Building National Certified Nurse-Midwife Interactive Leaflet Map ===")

# 1. ZCTA internal points, Census 2020 Gazetteer
zip_coords = {}
with zipfile.ZipFile(ZCTA_GAZ_ZIP) as zf:
    name = [n for n in zf.namelist() if n.endswith(".txt")][0]
    with zf.open(name) as fh:
        reader = csv.reader(io.TextIOWrapper(fh, encoding="utf-8"), delimiter="\t")
        header = [h.strip() for h in next(reader)]
        i_geo, i_lat, i_lon = header.index("GEOID"), header.index("INTPTLAT"), header.index("INTPTLONG")
        for row in reader:
            zip_coords[row[i_geo].strip()] = (float(row[i_lat]), float(row[i_lon]))
print(f"Loaded {len(zip_coords):,} ZCTA internal points from {ZCTA_GAZ_ZIP}.")

# 2. Geocoded obstetric hospitals, keyed on street address + state
hosp_coords = {}
with open(HOSP_GEO_FILE, "r", encoding="utf-8", errors="ignore") as f:
    for r in csv.DictReader(f):
        addr = r.get("geocode_address_1", "").upper().strip()
        st = r.get("geocode_state", "").upper().strip()
        try:
            lat, lon = float(r["latitude"]), float(r["longitude"])
        except (ValueError, TypeError):
            continue
        if addr and st and lat and lon:
            hosp_coords[f"{addr}_{st}"] = (lat, lon, r.get("fac_name", "").strip())

# 3. The roster
mws = []
n_roster = 0
n_unplaced = 0
with open(ROSTER_FILE, "r", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        n_roster += 1
        state = r["nppes_state"].upper().strip()
        zip5 = r["nppes_zip"][:5]
        addr = r["nppes_practice_address"].upper().strip()

        hosp = hosp_coords.get(f"{addr}_{state}")
        if hosp:
            lat, lon, placed = hosp[0], hosp[1], f"at the geocoded hospital address ({hosp[2]})"
        elif zip5 in zip_coords:
            lat, lon = zip_coords[zip5]
            placed = f"at the centre of ZIP {zip5}, not the street address"
        else:
            n_unplaced += 1
            continue

        board_state = r["board_state"]
        mws.append({
            "npi": r["npi"],
            "cert": r["certification_number"],
            "name": f"{r['first_name']} {r['last_name']}".strip(),
            "address": r["nppes_practice_address"],
            "city": r["nppes_city"].title(),
            "state": state,
            "zip": zip5,
            "placed": placed,
            "board_state": board_state,
            "board_name": BOARD_NAME.get(board_state, ""),
            "board_lic": r["board_license_number"],
            "board_status": r["board_license_status"],
            "board_exp": r["board_license_expiration"][:10],
            "board_url": BOARD_DATASET_URL.get(board_state, ""),
            "state_queried": state in BOARD_DATASET_URL,
            "lat": round(lat, 5),
            "lon": round(lon, 5),
        })

n_mapped = len({m["npi"] for m in mws})
states_mapped = sorted({m["state"] for m in mws} & STATES_AND_DC)
states_absent = sorted(STATES_AND_DC - {m["state"] for m in mws})
n_board = sum(1 for m in mws if m["board_state"])
n_at_hospital = sum(1 for m in mws if m["placed"].startswith("at the geocoded"))
print(f"Roster rows: {n_roster:,}; mapped: {len(mws):,} ({n_mapped:,} NPIs); "
      f"no ZIP point: {n_unplaced:,}.")
print(f"States + DC with at least one midwife: {len(states_mapped)}; absent: {', '.join(states_absent)}")
print(f"Board licence on record ({', '.join(BOARDS_QUERIED)} only): {n_board:,}")

fmt = lambda n: f"{n:,}"
subtitle = (
    f"NPPES practice locations of {fmt(n_mapped)} ACTIVE AMCB-certified midwives linked "
    f"to an NPI (2026-08-10 freeze), in the {len(states_mapped)} states the tracked roster "
    f"covers. Not shown: {', '.join(states_absent)}, and {fmt(n_unplaced)} of the roster's "
    f"{fmt(n_roster)} whose NPPES ZIP has no Census ZCTA point. "
    f"State board licence is shown only where the {', '.join(BOARD_NAME[s] for s in BOARDS_QUERIED)} "
    f"open-data files returned one; no other board was queried."
)

# 4. Generate Interactive Leaflet HTML
midwives_json = json.dumps(mws)

html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>National Certified Nurse-Midwife (CNM) Interactive Workforce Map</title>
    <!-- Leaflet CSS -->
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <!-- Leaflet MarkerCluster CSS -->
    <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.css" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.Default.css" />
    <!-- Google Fonts -->
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        * {{ box-sizing: border-box; margin: 0; padding: 0; font-family: 'Inter', sans-serif; }}
        body, html {{ height: 100%; width: 100%; overflow: hidden; background: #0f172a; color: #f8fafc; }}
        #map {{ height: 100vh; width: 100vw; position: absolute; top: 0; left: 0; z-index: 1; }}

        /* Glassmorphic Floating Header Card */
        .header-card {{
            position: absolute; top: 20px; left: 20px; z-index: 1000;
            background: rgba(15, 23, 42, 0.85); backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 16px;
            padding: 20px 24px; max-width: 440px; width: calc(100% - 40px);
            box-shadow: 0 20px 40px rgba(0,0,0,0.5);
        }}
        .header-card h1 {{ font-size: 20px; font-weight: 700; color: #f8fafc; margin-bottom: 4px; letter-spacing: -0.5px; }}
        .header-card p {{ font-size: 12px; color: #94a3b8; line-height: 1.45; margin-bottom: 16px; }}

        /* Stats Grid */
        .stats-grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-bottom: 16px; }}
        .stat-box {{ background: rgba(30, 41, 59, 0.7); padding: 10px 12px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.05); }}
        .stat-val {{ font-size: 18px; font-weight: 700; color: #38bdf8; }}
        .stat-lbl {{ font-size: 10px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.5px; margin-top: 2px; }}

        /* Controls */
        .filter-group {{ display: flex; flex-direction: column; gap: 10px; }}
        select, input {{
            width: 100%; background: #1e293b; color: #f8fafc; border: 1px solid #334155;
            padding: 10px 14px; border-radius: 8px; font-size: 13px; outline: none;
            transition: all 0.2s ease;
        }}
        select:focus, input:focus {{ border-color: #38bdf8; box-shadow: 0 0 0 2px rgba(56, 189, 248, 0.2); }}

        /* Legend Card */
        .legend-card {{
            position: absolute; bottom: 30px; left: 20px; z-index: 1000;
            background: rgba(15, 23, 42, 0.85); backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 12px;
            padding: 14px 18px; font-size: 12px;
        }}
        .legend-item {{ display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }}
        .legend-item:last-child {{ margin-bottom: 0; }}
        .dot {{ width: 12px; height: 12px; border-radius: 50%; display: inline-block; }}

        /* Custom Leaflet Popups */
        .leaflet-popup-content-wrapper {{
            background: #0f172a !important; color: #f8fafc !important;
            border: 1px solid rgba(255,255,255,0.15); border-radius: 12px !important;
            box-shadow: 0 15px 30px rgba(0,0,0,0.6) !important; padding: 4px;
        }}
        .leaflet-popup-tip {{ background: #0f172a !important; }}
        .popup-title {{ font-size: 16px; font-weight: 700; color: #38bdf8; margin-bottom: 6px; }}
        .popup-detail {{ font-size: 12px; color: #94a3b8; line-height: 1.5; }}
    </style>
</head>
<body>
    <div id="map"></div>

    <div class="header-card">
        <h1>National CNM Workforce Map</h1>
        <p>{subtitle}</p>

        <div class="stats-grid">
            <div class="stat-box">
                <div class="stat-val">{fmt(n_mapped)}</div>
                <div class="stat-lbl">Midwives mapped</div>
            </div>
            <div class="stat-box">
                <div class="stat-val">{len(states_mapped)}</div>
                <div class="stat-lbl">States covered</div>
            </div>
            <div class="stat-box">
                <div class="stat-val" style="color: #34d399;">{fmt(n_board)}</div>
                <div class="stat-lbl">Board licence on record ({"/".join(BOARDS_QUERIED)})</div>
            </div>
        </div>

        <div class="filter-group">
            <input type="text" id="searchInput" placeholder="Search by name, city, state..." oninput="updateMap()">
            <select id="settingFilter" onchange="updateMap()">
                <option value="ALL">All mapped midwives</option>
                <option value="BOARD_ONLY">State board licence on record ({"/".join(BOARDS_QUERIED)} only)</option>
            </select>
        </div>
    </div>

    <div class="legend-card">
        <div class="legend-item"><span class="dot" style="background:#34d399;"></span> Licence returned by a state board file ({fmt(n_board)})</div>
        <div class="legend-item"><span class="dot" style="background:#3B82F6;"></span> NPPES practice location; board not queried or no match ({fmt(len(mws) - n_board)})</div>
        <div class="legend-item" style="color:#94a3b8;">{fmt(n_at_hospital)} placed on a geocoded hospital, the rest on a ZIP centre</div>
    </div>

    <!-- Leaflet JS -->
    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
    <script src="https://unpkg.com/leaflet.markercluster@1.5.3/dist/leaflet.markercluster.js"></script>
    <script>
        const midwivesData = {midwives_json};

        // Initialize Leaflet Map with Dark Tiles
        const map = L.map('map', {{ center: [39.8283, -98.5795], zoom: 4 }});
        L.tileLayer('https://{{s}}.basemaps.cartocdn.com/dark_all/{{z}}/{{x}}/{{y}}{{r}}.png', {{
            attribution: '&copy; OpenStreetMap &copy; CARTO',
            maxZoom: 18
        }}).addTo(map);

        let markerCluster = L.markerClusterGroup({{ disableClusteringAtZoom: 12 }});
        map.addLayer(markerCluster);

        function getCircleIcon(color) {{
            return L.divIcon({{
                className: 'custom-icon',
                html: `<div style="background-color: ${{color}}; width: 12px; height: 12px; border-radius: 50%; border: 2px solid white; box-shadow: 0 0 8px ${{color}};"></div>`,
                iconSize: [12, 12],
                iconAnchor: [6, 6]
            }});
        }}

        function updateMap() {{
            markerCluster.clearLayers();
            const searchVal = document.getElementById('searchInput').value.toLowerCase();
            const settingVal = document.getElementById('settingFilter').value;

            const filtered = midwivesData.filter(m => {{
                const matchSearch = m.name.toLowerCase().includes(searchVal) ||
                                    m.city.toLowerCase().includes(searchVal) ||
                                    m.state.toLowerCase().includes(searchVal);
                const matchSetting = settingVal === 'BOARD_ONLY' ? m.board_state !== '' : true;
                return matchSearch && matchSetting;
            }});

            const markers = filtered.map(m => {{
                const npiUrl = `https://npiregistry.cms.hhs.gov/provider-view/${{m.npi}}`;
                const amcbUrl = "https://ams.amcbmidwife.org/amcbssa/f?p=AMCBSSA:17800";

                // Board licence only where a state board's own open-data file
                // returned it (WA DOH, Colorado DORA, Texas BON). Its status is
                // shown as the board reported it, Expired included. No other
                // board was queried, and the popup says so rather than implying
                // a check that did not happen.
                let bonLine;
                if (m.board_state) {{
                    bonLine = `<b>State board licence:</b> ${{m.board_lic}} (${{m.board_status}}${{m.board_exp ? ', expires ' + m.board_exp : ''}}), ` +
                              `<a href="${{m.board_url}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{m.board_name}} open data</a>, matched by name<br>`;
                }} else if (m.state_queried) {{
                    bonLine = `<b>State board licence:</b> no name match in the ${{m.state}} board file<br>`;
                }} else {{
                    bonLine = `<b>State board licence:</b> not queried for ${{m.state}}<br>`;
                }}

                const popupContent = `
                    <div class="popup-title">
                        <a href="${{npiUrl}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{m.name}}</a>
                    </div>
                    <div class="popup-detail">
                        <b>NPI:</b> <a href="${{npiUrl}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{m.npi}}</a> (NPPES Registry)<br>
                        <b>Certification #:</b> <a href="${{amcbUrl}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{m.cert}}</a> (AMCB Roster)<br>
                        ${{bonLine}}
                        <b>Practice address:</b> ${{m.address}}, ${{m.city}}, ${{m.state}} ${{m.zip}} (NPPES)<br>
                        <b>Marker placed:</b> ${{m.placed}}
                    </div>
                `;

                const marker = L.marker([m.lat, m.lon], {{ icon: getCircleIcon(m.board_state ? '#34d399' : '#3B82F6') }});
                marker.bindPopup(popupContent);
                return marker;
            }});

            markerCluster.addLayers(markers);
        }}

        updateMap();
    </script>
</body>
</html>
"""

with open(OUT_HTML, "w", encoding="utf-8") as f:
    f.write(html_content)

print(f"\n=========================================================================")
print(f"  SUCCESSFULLY GENERATED CNM INTERACTIVE LEAFLET MAP: {OUT_HTML}")
print(f"=========================================================================")
