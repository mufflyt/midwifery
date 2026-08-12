#!/usr/bin/env python3
# =============================================================================
# National Certified Nurse-Midwife (CNM) Interactive Leaflet Map Generator
# =============================================================================
import csv
import json
import os
import re

MASTER_V4_FILE = "artifacts/cohort_midwife_facility_attributions_final_v4.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
HOSP_GEO_FILE = "artifacts/ob_hospitals_geocoded.csv"
ZIP_GEO_FILE = "data/us_zip_centroids.csv"
OUT_HTML = "docs/cnm_national_leaflet_map.html"

print("=== Building National Certified Nurse-Midwife Interactive Leaflet Map ===")

# 1. Load US Census ZIP Code Centroids
zip_coords = {}
with open(ZIP_GEO_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        z = r.get("zip", "").zfill(5)
        try:
            zip_coords[z] = (float(r["latitude"]), float(r["longitude"]))
        except ValueError:
            pass

print(f"Loaded {len(zip_coords):,} US ZIP code coordinates.")

# 2. Load Hospital Exact Geocodes and Enhanced CMS CCN Lookup
hosp_coords = {}
with open(HOSP_GEO_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        addr = r.get("geocode_address_1", "").upper().strip()
        st = r.get("geocode_state", "").upper().strip()
        try:
            lat = float(r["latitude"])
            lon = float(r["longitude"])
            if lat and lon:
                hosp_coords[f"{addr}_{st}"] = (lat, lon)
        except (ValueError, TypeError):
            pass

hosp_ccn_map = {}
if os.path.exists("data/CMS_Hospital_General_Information.csv"):
    with open("data/CMS_Hospital_General_Information.csv", "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        for r in reader:
            name = r.get("Facility Name", "").upper().strip()
            city = r.get("City/Town", "").upper().strip()
            st = r.get("State", "").upper().strip()
            ccn = r.get("Facility ID", "").strip()
            if name and ccn:
                hosp_ccn_map[name] = ccn
                hosp_ccn_map[f"{name}_{st}"] = ccn
                hosp_ccn_map[f"{name}_{city}_{st}"] = ccn

print(f"Mapped {len(hosp_ccn_map):,} CMS Hospitals to exact 6-digit CCN Facility IDs.")

# 3. Load Master Midwife Cohort v4 (N = 11,920)
mws = []
with open(MASTER_V4_FILE, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        npi = r.get("npi", "").strip()
        zip_code = r.get("nppes_zip", r.get("zip", ""))[:5].zfill(5)
        state = r.get("nppes_state", r.get("state", "")).upper().strip()
        city = r.get("nppes_city", r.get("city", "")).title().strip()
        
        addr1 = r.get("nppes_practice_address", r.get("practice_address_1", "")).upper()
        h_key = f"{addr1}_{state}"
        
        # Determine Lat / Lon Coordinates
        lat, lon = None, None
        if h_key in hosp_coords:
            lat, lon = hosp_coords[h_key]
        elif zip_code in zip_coords:
            lat, lon = zip_coords[zip_code]
            
        if lat and lon:
            # Color Category & Tier
            setting = r.get("refined_clinical_setting", "")
            has_cpt = r.get("has_cpt_delivery_claim", "").upper() == "TRUE"
            
            if "1." in setting:
                category = "Hospital Privileges"
                color = "#3B82F6" # Blue
            elif "3." in setting:
                category = "Accredited Birth Center"
                color = "#10B981" # Emerald Green
            elif "2." in setting or "4." in setting or "5." in setting:
                category = "Hospital / Health System Group"
                color = "#8B5CF6" # Purple
            else:
                category = "Outpatient / Community Clinic"
                color = "#F59E0B" # Amber Gold
                
            facility_name = r.get("attributed_hospital_name", r.get("matched_cabc_birth_center", r.get("op_profile_match", "Outpatient Practice"))).strip()
            f_upper = facility_name.upper()
            city_upper = city.upper()
            
            facility_ccn = (
                r.get("cms_ccn", "").strip() or 
                hosp_ccn_map.get(f_upper) or 
                hosp_ccn_map.get(f"{f_upper}_{state}") or 
                hosp_ccn_map.get(f"{f_upper}_{city_upper}_{state}") or ""
            )
            
            mws.append({
                "npi": npi,
                "cert": r.get("certification_number", ""),
                "name": f"CNM {r.get('first_name', '')} {r.get('last_name', '')}".strip(),
                "setting": setting,
                "category": category,
                "color": color,
                "facility": facility_name,
                "ccn": facility_ccn,
                "address": r.get("nppes_practice_address", r.get("practice_address_1", "")),
                "city": city,
                "state": state,
                "zip": zip_code,
                "cpt_claims": "Active Attending Delivery Provider (CPT 59400/59409/59410)" if has_cpt else "Outpatient / Clinic Practice",
                "has_cpt": has_cpt,
                "op_status": r.get("open_payments_status", "Unlinked"),
                "lat": round(lat, 5),
                "lon": round(lon, 5)
            })

print(f"Prepared {len(mws):,} midwives with valid map coordinates.")

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
            padding: 20px 24px; max-width: 420px; width: calc(100% - 40px);
            box-shadow: 0 20px 40px rgba(0,0,0,0.5);
        }}
        .header-card h1 {{ font-size: 20px; font-weight: 700; color: #f8fafc; margin-bottom: 4px; letter-spacing: -0.5px; }}
        .header-card p {{ font-size: 13px; color: #94a3b8; line-height: 1.4; margin-bottom: 16px; }}
        
        /* Stats Grid */
        .stats-grid {{ display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; margin-bottom: 16px; }}
        .stat-box {{ background: rgba(30, 41, 59, 0.7); padding: 10px 12px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.05); }}
        .stat-val {{ font-size: 18px; font-weight: 700; color: #38bdf8; }}
        .stat-lbl {{ font-size: 11px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.5px; margin-top: 2px; }}
        
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
        .popup-sub {{ font-size: 12px; color: #cbd5e1; margin-bottom: 8px; font-weight: 500; }}
        .popup-badge {{
            display: inline-block; padding: 4px 8px; border-radius: 6px; font-size: 11px;
            font-weight: 600; margin-bottom: 8px;
        }}
        .badge-active {{ background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.4); }}
        .badge-clinic {{ background: rgba(245, 158, 11, 0.2); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.4); }}
        .popup-detail {{ font-size: 12px; color: #94a3b8; line-height: 1.5; }}
    </style>
</head>
<body>
    <div id="map"></div>

    <div class="header-card">
        <h1>National CNM Workforce Map</h1>
        <p>Interactive spatial distribution of 11,920 Certified Nurse-Midwives across clinical delivery settings.</p>
        
        <div class="stats-grid">
            <div class="stat-box">
                <div class="stat-val">11,920</div>
                <div class="stat-lbl">Active Cohort</div>
            </div>
            <div class="stat-box">
                <div class="stat-val" style="color: #34d399;">7,470</div>
                <div class="stat-lbl">Delivery Attenders</div>
            </div>
            <div class="stat-box">
                <div class="stat-val" style="color: #60a5fa;">2,611</div>
                <div class="stat-lbl">Hospital Attenders</div>
            </div>
            <div class="stat-box">
                <div class="stat-val" style="color: #a78bfa;">221</div>
                <div class="stat-lbl">Birth Centers</div>
            </div>
        </div>

        <div class="filter-group">
            <input type="text" id="searchInput" placeholder="Search by CNM name, hospital, city..." oninput="updateMap()">
            <select id="settingFilter" onchange="updateMap()">
                <option value="ALL">All Clinical Settings</option>
                <option value="Hospital Privileges">Hospital Main Campus / Privileges</option>
                <option value="Accredited Birth Center">Accredited Freestanding Birth Centers</option>
                <option value="Hospital / Health System Group">Municipal & Metro Health Groups</option>
                <option value="Outpatient / Community Clinic">Outpatient Community Practices</option>
                <option value="CPT_DELIVERY_ONLY">Active CPT Delivery Attenders Only</option>
            </select>
        </div>
    </div>

    <div class="legend-card">
        <div class="legend-item"><span class="dot" style="background:#3B82F6;"></span> Hospital Main Campus / Privileges</div>
        <div class="legend-item"><span class="dot" style="background:#10B981;"></span> Accredited Freestanding Birth Center</div>
        <div class="legend-item"><span class="dot" style="background:#8B5CF6;"></span> Health System / Municipal Group</div>
        <div class="legend-item"><span class="dot" style="background:#F59E0B;"></span> Outpatient Community Practice</div>
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
                                    m.facility.toLowerCase().includes(searchVal) ||
                                    m.city.toLowerCase().includes(searchVal) ||
                                    m.state.toLowerCase().includes(searchVal);
                
                let matchSetting = true;
                if (settingVal === 'CPT_DELIVERY_ONLY') {{
                    matchSetting = m.has_cpt === true;
                }} else if (settingVal !== 'ALL') {{
                    matchSetting = m.category === settingVal;
                }}

                return matchSearch && matchSetting;
            }});

            const markers = filtered.map(m => {{
                const badgeClass = m.has_cpt ? 'badge-active' : 'badge-clinic';
                const npiUrl = `https://npiregistry.cms.hhs.gov/provider-view/${{m.npi}}`;
                const openPaymentsUrl = "https://openpaymentsdata.cms.gov/search";
                const cmsCptUrl = "https://data.cms.gov/provider-summary-by-type-of-service/medicare-physician-other-practitioners";
                const amcbUrl = "https://ams.amcbmidwife.org/amcbssa/f?p=AMCBSSA:17800";
                const cmsHospUrl = "https://data.cms.gov/provider-data/topics/hospitals";
                const cabcUrl = "https://birthcenteraccreditation.org/find-accredited-birth-center/";
                
                const facilityUrl = m.category === "Accredited Birth Center" ? cabcUrl : cmsHospUrl;
                const facilityLabel = m.category === "Accredited Birth Center" ? `🏥 ${{m.facility}} (CABC Directory)` : `🏥 ${{m.facility}} (CMS Hospital Provider Data)`;
                
                const popupContent = `
                    <div class="popup-title">
                        <a href="${{npiUrl}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{m.name}}</a>
                    </div>
                    <div class="popup-sub">
                        <a href="${{facilityUrl}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{facilityLabel}}</a>
                    </div>
                    <a href="${{cmsCptUrl}}" target="_blank" style="text-decoration: none;">
                        <div class="popup-badge ${{badgeClass}}">${{m.cpt_claims}} 🔗</div>
                    </a>
                    <div class="popup-detail">
                        <b>NPI:</b> <a href="${{npiUrl}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{m.npi}}</a> (NPPES Registry)<br>
                        <b>Certification #:</b> <a href="${{amcbUrl}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{m.cert}}</a> (AMCB Roster)<br>
                        <b>Practice Address:</b> <a href="${{npiUrl}}" target="_blank" style="color: #94a3b8; text-decoration: underline;">${{m.address}}, ${{m.city}}, ${{m.state}} ${{m.zip}}</a> (CMS NPPES File)<br>
                        <b>Setting Tier:</b> ${{m.setting}}<br>
                        <b>Sunshine Act:</b> <a href="${{openPaymentsUrl}}" target="_blank" style="color: #38bdf8; text-decoration: underline;">${{m.op_status}}</a>
                    </div>
                `;

                const marker = L.marker([m.lat, m.lon], {{ icon: getCircleIcon(m.color) }});
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
