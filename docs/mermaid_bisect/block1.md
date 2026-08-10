# Mermaid bisect — block 1

Isolated from `README.md` line 9. If this page renders the diagram, the block is fine on its own; if it shows *"Unable to render rich display"*, this is the block breaking the README.

```mermaid
flowchart LR
  A["AMCB directory - 22,309 names"] --> B["Candidate generation - 197,081 pairs"]
  B --> C["Name-evidence class 1 to 4"]
  C --> D["Accepted links - 16,892"]
  C --> Q["Quarantined - 3,091"]
  D --> E["Last-observed practice address"]
  E --> F["Geocode and county - 99% of linked"]
```
