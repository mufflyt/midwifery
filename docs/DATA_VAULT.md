# The data vault: sharing person-level inputs across machines

This project runs on more than one computer, and its person-level inputs are
deliberately not in git. That combination failed on 2026-09-13. The AMCB–NPI
linkage freeze had been regenerated three times in two days under one filename
(sha256 `7473a8a6…`, then `b84e07ec…`, then `1a7bd6a8…`), and the current one
existed only on the machine that built it. Another machine had an older copy
(`dbcc76f4…`, the 2026-08-10 freeze) lying in `artifacts/`, and a build ran
against it and described 11,920 midwives instead of the registered 12,171.

The vault is one shared folder for those files, with two rules. Files are
found by content, not by name, and nothing in it is ever overwritten.

## What goes where

| What | Where | Why |
|---|---|---|
| Code, tracked aggregates, manifests, provenance sidecars | the git repository, cloned on each machine | versioned and reviewed |
| Person-level inputs: the linkage freeze, practice locations, DAC/PECOS extracts, the Trilliant work-site outputs | the vault, `Dropbox/midwifery-data/` | shared, and too sensitive for git |
| Large warehouses: the Medicare DuckDB (~84 GB), the Trilliant lake (~148 GB), NPPES full files | the Samsung external drive (`samsung_volume_path()`) | too big to sync |

**Never put the git repository itself in Dropbox.** Syncing `.git`, or a DuckDB
database that is open, produces "conflicted copy" files and corrupts both.

## Setting up a machine

1. Install Dropbox and create a folder named `midwifery-data` in it.
2. Right-click the folder and choose **Make available offline**. An
   online-only file is a zero-byte placeholder until it downloads, and the
   vault refuses those. This is the same eviction that left `.icloud`
   placeholders where the linkage freeze should have been.
3. Nothing else is needed if Dropbox is in a standard place. `vault_root()`
   checks, in order: the `MIDWIFERY_VAULT` environment variable, the folder
   Dropbox's own config names (`~/.dropbox/info.json`),
   `~/Library/CloudStorage/Dropbox*`, then `~/Dropbox*`. If it finds none, or
   finds more than one, it stops and tells you to set `MIDWIFERY_VAULT`.

## File names

    <stem>_<first 8 hex of sha256>_<YYYY-MM-DD>.<ext>
    amcb_npi_linkage_FROZEN_1a7bd6a8_2026-09-10.csv

Two versions of a file are two files. The tracked manifest
(`artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json`) records which full
sha256 is current. `vault_find()` re-hashes the vault copy against it, so a
stale, partial or tampered file stops the build instead of being used.

## Publishing a file

From the machine that has it, in the repository root:

    # the current linkage freeze -- refused unless it is the one the manifest describes
    Rscript publish_to_data_vault.R

    # any other person-level input
    Rscript publish_to_data_vault.R artifacts/midwife_practice_locations.csv midwife_practice_locations 2026-09-10

`vault_publish()` copies the file to a `.partial` name, checks that the copy
hashes like the source, then renames it. Publishing the same file twice does
nothing. Publishing different contents under a name that is already taken is
refused.

## Using it from code

    source(file.path("R", "lib", "data_vault.R"))
    frozen <- vault_linkage_freeze()      # artifacts/ copy if it is the manifest's freeze, else the vault's
    locs   <- vault_latest("midwife_practice_locations")   # newest by the date in its name

`vault_linkage_freeze()` is the one to use for the cohort. `vault_latest()` is
for inputs no manifest pins. It picks the newest by the date in the name, not
the file's modified time, which syncing rewrites, and the caller's provenance
sidecar records the chosen file's hash.

A tracked sidecar must not record a vault path, because it is absolute and
names a home directory, which `ci_repo_integrity.R` rejects. Record vault
inputs in the sidecars of the person-level outputs, which are gitignored, and
carry the freeze's hash into tracked outputs as a column (as
`build_trilliant_work_sites.R` does with `frozen_sha256`).

## Before you store anything here

The vault holds names, NPIs and practice addresses, and the Trilliant extracts
are licensed data. Confirm that Trilliant's license terms and Denver Health's
data policy allow a personal Dropbox for them. If they do not, point
`MIDWIFERY_VAULT` at the institution's approved storage instead. The code does
not care where the folder is, only that it holds the right bytes.

## The file this was built for

The current freeze, `amcb_npi_linkage_FROZEN.csv` (22,357 rows, sha256
`1a7bd6a8c8f1c08910d3f2a9cb24561ed858a6b1204bf2274fdd3a8bd0887da2`, run
`reconcile_ab_20260910T193000_issue172`), was built on 2026-09-10 (commit
`abd325b`). To publish it, run `shasum -a 256 artifacts/amcb_npi_linkage_FROZEN.csv`
on the machine that has it and check that the result starts with `1a7bd6a8`.
Then run `Rscript publish_to_data_vault.R` there. Every other machine then
finds it with `vault_linkage_freeze()`.
