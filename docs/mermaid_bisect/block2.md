# Mermaid bisect — block 2

Isolated from `README.md` line 59. If this page renders the diagram, the block is fine on its own; if it shows *"Unable to render rich display"*, this is the block breaking the README.

```mermaid
flowchart TD
  A["AMCB directory - 22,309 names, no location"] --> B["Candidate generation - 197,081 pairs"]
  P["NPPES 2007-2025 - 443,623 NPIs"] --> B
  B --> C["Rank by name-evidence class"]
  C --> D{"One candidate at the strongest class?"}
  D -->|no| Q["Quarantined - 3,091"]
  D -->|yes| E{"One NPI, one person?"}
  E -->|contested| Q2["Quarantined - 91"]
  E -->|yes| F["Accepted links - 16,892"]
  F --> G["Last-observed practice address"]
  G --> H["Geocode - Census to ArcGIS to centroid"]
  G --> J["Unique-ZIP county"]
  H --> I["Point-in-polygon county"]
  I --> K["county_exact"]
  I --> L["county_best"]
  J --> L
```
