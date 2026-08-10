# Mermaid bisect — block 3

Isolated from `README.md` line 106. If this page renders the diagram, the block is fine on its own; if it shows *"Unable to render rich display"*, this is the block breaking the README.

```mermaid
flowchart LR
  S["Resolved candidate"] --> T1{"Fuzzy surname?"}
  T1 -->|yes| F["sensitivity_fuzzy - 328"]
  T1 -->|no| T2{"Midwifery taxonomy ever recorded?"}
  T2 -->|yes| P["primary_midwifery - 14,668"]
  T2 -->|no| N["sensitivity_nursing - 1,896"]
```
