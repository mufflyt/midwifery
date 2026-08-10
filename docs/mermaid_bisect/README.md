# Mermaid bisect

GitHub reports *"Cannot read properties of undefined (reading 'render')"* on the
project README and falls back to showing the diagram source as a code block.
Two speculative fixes — removing em dashes and `=`, then removing `<br/>` — did
not clear it, and the failure cannot be reproduced locally: `mermaid-cli`
requires a Chrome install that is not on this machine.

So each block is isolated here, one per file. Whichever page fails is the block
at fault; if every page renders, the blocks are individually valid and the
problem is an interaction between them or something else in the README.

| file | from README line | diagram |
|---|---|---|
| [block1.md](block1.md) | 9 | linkage overview (`flowchart LR`) |
| [block2.md](block2.md) | 59 | full pipeline (`flowchart TD`) |
| [block3.md](block3.md) | 106 | tier assignment (`flowchart LR`) |
| [block4.md](block4.md) | 140 | geocoding cascade (`flowchart TD`) |

Delete this directory once the culprit is found.
