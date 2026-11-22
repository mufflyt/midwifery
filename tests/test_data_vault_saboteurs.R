#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: the data vault's custody rules (R/lib/data_vault.R)
# =============================================================================
# tests/test_data_vault.R covers the vault's intended paths -- publish, find,
# latest, where, and the three states of vault_linkage_freeze(). This file does
# not repeat them. It attacks the custody guarantees from outside: a name that
# lies about its contents, a hash prefix that collides, a crashed publish, an
# evicted placeholder, a stem that is really a regular expression, and a
# rename that fails.
#
# WHY THIS FILE EXISTS. The vault was built after 2026-09-13, when a build ran
# against a freeze from a different machine and described 11,920 midwives
# instead of 12,171. Its whole value is that it cannot do that again -- so the
# question is not "does publishing work" but "what gets past it". On
# 2026-11-14 the same class of failure recurred in a new place: the freeze the
# manifest names existed on exactly one machine, and the vault on that machine
# held the PREVIOUS vintage. Custody code that is only ever exercised on its
# happy path is custody code nobody has tested.
#
# HONESTY RULE, inherited from tests/test_table1_saboteurs.R: where a saboteur
# finds a REAL GAP rather than confirming a guard, it says so and asserts the
# behaviour that exists today. A green test that pretends a gap is closed is
# worse than a red one. Six of the twenty below are gaps; each is marked GAP
# and names what it would take to close it.
#
# Run:  Rscript tests/test_data_vault_saboteurs.R
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "data_vault.R"))

fails <- 0L
gaps  <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}
gap <- function(what) {
  gaps <<- gaps + 1L
  cat(sprintf("       GAP: %s\n", what))
}

# A fresh, empty vault per saboteur: a test that inherits another's files is
# testing the leftovers, not the rule.
new_vault <- function() {
  d <- tempfile("vault_sab_")
  dir.create(d, recursive = TRUE)
  d
}
put <- function(dir, name, content) {
  p <- file.path(dir, name)
  writeLines(content, p)
  p
}
# file.rename/file.copy/file.create return a logical. At top level that logical
# PRINTS, burying the assertions in "[1] TRUE". Wrap, rather than scatter
# invisible() through twenty saboteurs.
mv    <- function(from, to) invisible(file.rename(from, to))
cp    <- function(from, to) invisible(file.copy(from, to))
touch <- function(p)        invisible(file.create(p))
sha_of <- function(p) digest::digest(file = p, algo = "sha256")
# The name the vault WOULD give this file, so a saboteur can hand-build a
# plausible-looking vault entry and then make it lie.
honest_name <- function(p, stem, date, ext = "csv") vault_name(stem, sha_of(p), date, ext)
# Named vault_err, not errs: tests/test_cycle11_spatial.R already defines errs()
# at top level, and hygiene gate H4 fails on a function defined in two tracked
# files. H4 only scans TRACKED files, so this collision is invisible until the
# file is git-added -- which is how the same mistake got through on 2026-11-13.
vault_err <- function(expr) tryCatch({ expr; NA_character_ }, error = function(e) conditionMessage(e))

old_env <- Sys.getenv("MIDWIFERY_VAULT", unset = NA_character_)
on.exit({
  if (is.na(old_env)) Sys.unsetenv("MIDWIFERY_VAULT")
  else Sys.setenv(MIDWIFERY_VAULT = old_env)
}, add = TRUE)

# =============================================================================
# A name that lies. The vault's central promise is that files are found by
# CONTENT, not by name -- so every one of these hands it a correct-looking
# name over the wrong bytes.
# =============================================================================
cat("\n-- a name that lies about its contents --\n")

# S1. The canonical attack: take an honest vault entry and swap its bytes,
# leaving the name alone. This is the 2026-09-13 failure in miniature -- the
# right filename, the wrong freeze -- and the re-hash in vault_find() is the
# only thing standing between it and a published number.
v <- new_vault()
p <- put(v, "tmp.csv", c("a,b", "1,2"))
nm <- honest_name(p, "thing", "2026-01-01")
mv(p, file.path(v, nm))
claimed <- sha_of(file.path(v, nm))
writeLines(c("a,b", "9,9"), file.path(v, nm))   # same name, different file
e <- vault_err(vault_find("thing", claimed, root = v))
chk(!is.na(e) && grepl("hashes to", e, fixed = TRUE),
    "S1 a vault file whose bytes were swapped under an honest name is REFUSED")

# S2. The refusal must name the file and both digests. A custody error that
# says only "mismatch" sends the reader to the wrong machine.
chk(!is.na(e) && grepl(substr(claimed, 1, 8), e, fixed = TRUE) && grepl(basename(nm), e, fixed = TRUE),
    "S2 the refusal names the offending file and the hash it claimed")

# S3. Case: a manifest that records an UPPERCASE digest must still resolve.
# jsonlite hands back whatever the JSON holds, and a hand-edited manifest is
# where upper case comes from.
v <- new_vault()
p <- put(v, "tmp.csv", c("x", "1"))
s <- sha_of(p)
mv(p, file.path(v, vault_name("thing", s, "2026-02-02")))
chk(identical(basename(vault_find("thing", toupper(s), root = v)),
              vault_name("thing", s, "2026-02-02")),
    "S3 an UPPERCASE digest from a hand-edited manifest still resolves")

# =============================================================================
# Ambiguity. Two files that both look like the answer must stop the build, not
# produce whichever list.files() happened to return first.
# =============================================================================
cat("\n-- two files that both look like the answer --\n")

# S4. Same hash prefix, two different dates. list.files() is sorted, so a
# silent first-wins here would be stable, plausible and wrong forever.
v <- new_vault()
p <- put(v, "tmp.csv", c("x", "1"))
s <- sha_of(p)
cp(p, file.path(v, vault_name("thing", s, "2026-01-01")))
cp(p, file.path(v, vault_name("thing", s, "2026-02-02")))
unlink(p)
e <- vault_err(vault_find("thing", s, root = v))
chk(!is.na(e) && grepl("More than one vault file", e, fixed = TRUE),
    "S4 one hash under two dates STOPS rather than picking the first")

# S5. vault_latest() has its own tie: two files, same newest date. A median or
# a first-wins would hide which input an analysis actually read.
v <- new_vault()
p <- put(v, "tmp.csv", c("x", "1"))
writeLines(c("y", "2"), file.path(v, "other.csv"))
mv(p, file.path(v, "loc_aaaaaaaa_2026-03-03.csv"))
mv(file.path(v, "other.csv"), file.path(v, "loc_bbbbbbbb_2026-03-03.csv"))
e <- vault_err(vault_latest("loc", root = v))
chk(!is.na(e) && grepl("share the newest date", e, fixed = TRUE),
    "S5 two vault files sharing the newest date STOP rather than one winning")

# S6. GAP. vault_latest()'s pattern requires LOWERCASE hex. vault_name()
# always lowercases, so this cannot arise from the publisher -- but a file
# copied in by hand with uppercase hex is not rejected, it is INVISIBLE, and
# vault_latest() then reports the older file as newest.
v <- new_vault()
p <- put(v, "tmp.csv", c("x", "1"))
writeLines(c("y", "2"), file.path(v, "other.csv"))
mv(p, file.path(v, "loc_aaaaaaaa_2026-01-01.csv"))
mv(file.path(v, "other.csv"), file.path(v, "loc_ABCDEF12_2026-09-09.csv"))
got <- basename(vault_latest("loc", root = v))
chk(identical(got, "loc_aaaaaaaa_2026-01-01.csv"),
    "S6 an uppercase-hex vault file is silently INVISIBLE to vault_latest()")
gap(paste("vault_latest() returns the 2026-01-01 file while a newer 2026-09-09 file sits",
          "beside it unread. Anchor the pattern on [0-9a-fA-F]{8} and lowercase the",
          "comparison, or refuse any name in the stem's family that the pattern cannot parse."))

# =============================================================================
# A crashed or partial publish. vault_publish() writes to .partial and renames,
# so the question is what a crash between those two steps leaves behind.
# =============================================================================
cat("\n-- a publish that did not finish --\n")

# S7. A leftover .partial must not be findable. If it were, a half-copied
# freeze would be read as the real one.
v <- new_vault()
p <- put(v, "src.csv", c("x", "1"))
s <- sha_of(p)
cp(p, file.path(v, paste0(vault_name("thing", s, "2026-04-04"), ".partial")))
e <- vault_err(vault_find("thing", s, root = v))
chk(!is.na(e) && grepl("No thing_", e, fixed = TRUE),
    "S7 a leftover .partial is NOT findable -- a half-copied freeze cannot be read")

# S8. GAP, and the reason S9 matters. The leftover .partial also BLOCKS every
# future publish of those bytes: .partial is excluded from the same-hash scan,
# so vault_publish() proceeds to file.copy(tmp, overwrite = FALSE), which
# refuses to write over the debris. The vault wedges on its own crash residue
# and needs a human to delete a file nobody mentions.
e <- vault_err(vault_publish(p, "thing", date = "2026-04-04", root = v))
chk(!is.na(e) && grepl("copy to the vault failed", e, fixed = TRUE),
    "S8 a stale .partial BLOCKS republishing the same bytes until deleted by hand")
gap(paste("a crashed publish leaves a .partial that silently blocks all later publishes",
          "of that file, and the error -- 'copy to the vault failed' -- names the",
          ".partial path without saying it is stale debris that can simply be removed.",
          "Either unlink() a stale .partial whose bytes already hash correctly, or say",
          "so in the message. Compounds with S9: the failure that CREATES the debris is",
          "silent, and the failure it causes is cryptic."))

# S9. GAP. vault_publish() ends with `file.rename(tmp, dest)` and then
# `invisible(dest)` -- the rename's return value is never examined. When it
# fails (a full disk, a sync daemon holding the destination, a read-only
# vault), the caller is handed the destination path while the bytes are still
# at .partial, and S7/S8 then describe the aftermath exactly.
#
# Asserted against the source rather than by forcing a rename failure: making
# rename fail portably means squatting the destination, and a squatted
# destination is caught EARLIER, by the file.exists(dest) branch -- so no
# runtime scaffold can reach the unchecked line. A source assertion that says
# why is worth more than a scaffold that silently tests a different branch.
src <- paste(readLines(file.path(root, "R", "lib", "data_vault.R"), warn = FALSE), collapse = "\n")
chk(grepl("  file.rename(tmp, dest)\n  invisible(dest)", src, fixed = TRUE),
    "S9 vault_publish() still renames WITHOUT checking the result, then reports success")
gap(paste("one line -- if (!file.rename(tmp, dest)) stop(...) -- turns a silent",
          "non-publish into a loud one. Today the only symptom is a vault_find()",
          "failure on another machine, hours later, which is exactly the 2026-09-13",
          "shape. Related: a DIRECTORY squatting on the destination is refused by the",
          "file.exists() branch, but via digest()'s own 'pathname is not a file' error",
          "rather than the custody message that branch exists to print."))

# =============================================================================
# Eviction. The vault's documented enemy is the cloud placeholder: a zero-byte
# stub where the file should be. docs/DATA_VAULT.md leads with it.
# =============================================================================
cat("\n-- the evicted, zero-byte placeholder --\n")

# S10. vault_find() must refuse a zero-byte file BEFORE hashing it. The sha256
# of an empty file is a real, stable digest, so a name-only check would sail
# past and hand an analysis an empty cohort.
v <- new_vault()
touch(file.path(v, "thing_da39a3ee_2026-06-06.csv"))
e <- vault_err(vault_find("thing", paste0("da39a3ee", strrep("0", 56)), root = v))
chk(!is.na(e) && grepl("empty", e, fixed = TRUE) && grepl("available offline", e, fixed = TRUE),
    "S10 a zero-byte placeholder is refused as a placeholder, with the fix named")

# S11. vault_latest() has the same guard; without it, the newest name wins and
# the caller gets nothing.
v <- new_vault()
touch(file.path(v, "loc_aaaaaaaa_2026-07-07.csv"))
e <- vault_err(vault_latest("loc", root = v))
chk(!is.na(e) && grepl("empty", e, fixed = TRUE),
    "S11 vault_latest() refuses a zero-byte newest file rather than returning it")

# S12. GAP. vault_publish() has NO such guard. A zero-byte source publishes
# cleanly, and only the eventual reader fails -- on a different machine, with
# an error that blames the vault rather than the publisher.
v <- new_vault()
p <- file.path(v, "empty.csv"); touch(p)
pub <- vault_err(vault_publish(p, "thing", date = "2026-08-08", root = v))
chk(is.na(pub), "S12 vault_publish() ACCEPTS a zero-byte source without complaint")
gap(paste("the publisher will put a placeholder in the vault that vault_find() and",
          "vault_latest() both refuse to read. The asymmetry means the machine that",
          "caused the problem reports success and the machine that suffers it reports",
          "the error. Reject size 0 at publish time."))

# =============================================================================
# The stem is interpolated into a regular expression. Three functions build
# patterns with sprintf() and no escaping.
# =============================================================================
cat("\n-- the stem that is really a regular expression --\n")

# S13. GAP. A stem containing a regex metacharacter matches files it should
# not. "." is the one that matters: every real stem here is a filename, and a
# filename with a dot in it is ordinary.
v <- new_vault()
p <- put(v, "tmp.csv", c("x", "1"))
s <- sha_of(p)
mv(p, file.path(v, vault_name("aXb", s, "2026-09-09")))
found <- vault_err(vault_find("a.b", s, root = v))
chk(is.na(found), "S13 stem 'a.b' MATCHES the unrelated file 'aXb_...' -- the stem is unescaped")
gap(paste("vault_find(), vault_publish() and vault_latest() all sprintf() the stem into a",
          "pattern. A stem with '.', '+' or '(' matches the wrong family, and the",
          "re-hash is the only thing that then rejects it -- which it does, so this is a",
          "wrong-error bug rather than a wrong-data bug. Wrap the stem in",
          "\\Q...\\E or escape it."))

# S14. The re-hash is what contains S13. Prove it: the collided file is found
# by name and then refused on content, so no wrong bytes are ever returned.
v <- new_vault()
p <- put(v, "tmp.csv", c("x", "1"))
mv(p, file.path(v, vault_name("aXb", sha_of(file.path(v, "tmp.csv")), "2026-09-09")))
other <- digest::digest("something else entirely", algo = "sha256")
e <- vault_err(vault_find("a.b", other, root = v))
chk(!is.na(e), "S14 the regex collision is still caught by the content check, not returned")

# =============================================================================
# Publishing the same thing twice, and publishing a different thing under a
# taken name. "Nothing in it is ever overwritten" is the vault's second rule.
# =============================================================================
cat("\n-- idempotence, and refusing to overwrite --\n")

# S15. The same bytes under a DIFFERENT date must return the existing copy, not
# create a second one -- a second copy is precisely what makes vault_find()
# ambiguous (S4), so this guard prevents the vault from poisoning itself.
v <- new_vault()
p <- put(v, "src.csv", c("x", "1"))
first  <- vault_publish(p, "thing", date = "2026-01-01", root = v)
second <- vault_publish(p, "thing", date = "2026-02-02", root = v)
chk(identical(first, second) &&
      length(list.files(v, pattern = "^thing_")) == 1L,
    "S15 republishing the same bytes under a new date returns the FIRST copy, not a second")

# S16. Different bytes whose 8-hex prefix is already taken must stop by hand.
# A real prefix collision is astronomically unlikely; a hand-copied or
# truncated name is not, and that is what this branch actually catches.
v <- new_vault()
p <- put(v, "src.csv", c("x", "1"))
s <- sha_of(p)
decoy <- file.path(v, vault_name("thing", s, "2025-12-31"))
writeLines(c("different", "bytes"), decoy)      # right prefix, wrong contents
e <- vault_err(vault_publish(p, "thing", date = "2026-01-01", root = v))
chk(!is.na(e) && grepl("resolve by hand", e, fixed = TRUE),
    "S16 a taken hash prefix holding different bytes stops for a human")

# S17. The exact destination name, already present with different bytes, is the
# blunter version of S16 and must refuse rather than overwrite.
v <- new_vault()
p <- put(v, "src.csv", c("x", "1"))
s <- sha_of(p)
nm <- vault_name("thing", s, "2026-01-01")
writeLines(c("squatter"), file.path(v, nm))
e <- vault_err(vault_publish(p, "thing", date = "2026-01-01", root = v))
chk(!is.na(e) && grepl("refusing to overwrite", e, fixed = TRUE),
    "S17 an occupied destination name is never overwritten")

# =============================================================================
# vault_root(): where the vault is. A wrong answer here is worse than no
# answer, because it sends every lookup to a plausible empty folder.
# =============================================================================
cat("\n-- locating the vault --\n")

# S18. MIDWIFERY_VAULT pointing at a FILE, not a directory. dir.exists() is
# FALSE for a file, so this must stop; file.exists() would have accepted it.
tf <- tempfile(); touch(tf)
Sys.setenv(MIDWIFERY_VAULT = tf)
e <- vault_err(vault_root())
chk(!is.na(e) && grepl("does not exist", e, fixed = TRUE),
    "S18 MIDWIFERY_VAULT pointing at a file, not a directory, STOPS")

# S19. An empty MIDWIFERY_VAULT must not be treated as a set-but-missing path.
# Sys.setenv(X = "") leaves nzchar() FALSE, so discovery continues; an
# is.null()-style check here would stop with a nonsense message instead.
Sys.setenv(MIDWIFERY_VAULT = "")
e <- vault_err(vault_root())
chk(is.na(e) || !grepl("is set to , which does not exist", e, fixed = TRUE),
    "S19 an EMPTY MIDWIFERY_VAULT falls through to discovery, not a nonsense error")

# =============================================================================
# vault_linkage_freeze(): the function the 2026-09-13 incident was about. A
# local copy is used ONLY if it is the file the manifest describes.
# =============================================================================
cat("\n-- the local copy is used only if it is the right one --\n")

# S20. A local artifacts/ copy that is the WRONG freeze must be passed over in
# favour of the vault's verified copy. This is the whole incident: the stale
# local file was there, it was readable, and it was wrong.
v <- new_vault()
wd <- tempfile("repo_"); dir.create(file.path(wd, "artifacts"), recursive = TRUE)
right <- put(v, "right.csv", c("npi", "1"))
s_right <- sha_of(right)
mv(right, file.path(v, vault_name("amcb_npi_linkage_FROZEN", s_right, "2026-10-22")))
writeLines(c("npi", "999"), file.path(wd, "artifacts", "amcb_npi_linkage_FROZEN.csv"))  # stale
mf <- file.path(wd, "artifacts", "amcb_npi_linkage_FROZEN.csv.manifest.json")
writeLines(sprintf('{"artifact_sha256":"%s"}', s_right), mf)
Sys.setenv(MIDWIFERY_VAULT = v)
got <- vault_linkage_freeze(manifest = mf,
                            local = file.path(wd, "artifacts", "amcb_npi_linkage_FROZEN.csv"))
chk(identical(normalizePath(got), normalizePath(file.path(v, vault_name("amcb_npi_linkage_FROZEN", s_right, "2026-10-22")))),
    "S20 a stale local freeze is PASSED OVER for the vault's verified copy")

# =============================================================================
cat(sprintf("\n%s (%d failure(s), %d real gap(s) recorded)\n",
            if (fails == 0L) "PASS" else "FAILED", fails, gaps))
if (fails > 0L) quit(status = 1L)
