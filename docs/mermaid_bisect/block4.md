# Mermaid bisect — block 4

Isolated from `README.md` line 140. If this page renders the diagram, the block is fine on its own; if it shows *"Unable to render rich display"*, this is the block breaking the README.

```mermaid
flowchart TD
  A["Last-observed address, with its observation year"] --> B{"Already in geocode cache?"}
  B -->|yes| D["Coordinates"]
  B -->|no| C1["US Census - 86.9%"]
  C1 -->|fail| C2["ArcGIS - 9.2%"]
  C2 -->|fail| C3["City centroid"]
  C1 --> D
  C2 --> D
  D --> E{"Coordinate state matches ZIP state?"}
  E -->|no| X["Cross-state conflict - unresolved - 17"]
  E -->|yes| F["Point-in-polygon, TIGER 2023"]
  F --> G["county_exact - 98.9% of primary"]
  A --> H["Unique-ZIP county"]
  G --> I["county_best - 99.7% of primary"]
  H --> I
```
