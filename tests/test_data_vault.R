#!/usr/bin/env Rscript
# =============================================================================
# The data vault hands out the right file or nothing: R/lib/data_vault.R
# =============================================================================
# The linkage freeze was regenerated three times in two days under one name,
# and the current one existed on a single machine. The vault's whole value is
# that a lookup returns the file whose hash a tracked manifest records, or
# stops -- never a stale copy, a sync placeholder, or a silently overwritten
# file. Everything here runs against a temporary directory.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "data_vault.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}
vault_refuses <- function(expr) inherits(try(expr, silent = TRUE), "try-error")
vault_file_sha <- function(p) digest::digest(file = p, algo = "sha256")

vault <- file.path(tempdir(), "midwifery-data"); dir.create(vault)
src <- tempfile(fileext = ".csv"); writeLines(c("certification_number,npi", "A1,1000000001"), src)

cat("\n-- PUBLISH --\n")
dest <- vault_publish(src, "amcb_npi_linkage_FROZEN", date = "2026-09-10", root = vault)
chk(basename(dest) == sprintf("amcb_npi_linkage_FROZEN_%s_2026-09-10.csv", substr(vault_file_sha(src), 1, 8)),
    "T1 the name carries the stem, the first 8 hex of the sha256 and the build date")
chk(identical(vault_file_sha(dest), vault_file_sha(src)), "T2 the vault copy is byte-identical")
chk(!any(endsWith(list.files(vault), ".partial")), "T3 no partial file is left behind")
chk(identical(vault_publish(src, "amcb_npi_linkage_FROZEN", date = "2026-09-10", root = vault), dest),
    "T4 publishing the same file again is a no-op")
chk(identical(vault_publish(src, "amcb_npi_linkage_FROZEN", date = "2026-09-13", root = vault), dest) &&
      length(list.files(vault)) == 1L,
    "T5 the same file under a later date is not copied twice")

cat("\n-- FIND --\n")
chk(identical(vault_find("amcb_npi_linkage_FROZEN", vault_file_sha(src), root = vault), dest),
    "T6 found by its full hash")
chk(identical(vault_find("amcb_npi_linkage_FROZEN", toupper(vault_file_sha(src)), root = vault), dest),
    "T7 hash case does not matter")
chk(vault_refuses(vault_find("amcb_npi_linkage_FROZEN", strrep("0", 64), root = vault)),
    "T8 a hash the vault does not hold stops")
new <- tempfile(fileext = ".csv"); writeLines(c("certification_number,npi", "A1,1000000002"), new)
d2 <- vault_publish(new, "amcb_npi_linkage_FROZEN", date = "2026-09-11", root = vault)
chk(length(list.files(vault)) == 2L && identical(vault_file_sha(dest), vault_file_sha(src)),
    "T9 a new freeze is added beside the old one; the old one is untouched")

cat("\n-- REFUSES A WRONG FILE --\n")
writeLines(c("certification_number,npi", "A1,1999999999"), d2)
chk(vault_refuses(vault_find("amcb_npi_linkage_FROZEN", vault_file_sha(new), root = vault)),
    "T10 a vault file whose contents no longer match its name stops")
empty <- file.path(vault, sprintf("placeholder_%s_2026-09-12.csv", substr(strrep("a", 64), 1, 8)))
invisible(file.create(empty))
chk(vault_refuses(vault_find("placeholder", strrep("a", 64), root = vault)),
    "T11 a zero-byte online-only placeholder stops")
chk(vault_refuses(vault_publish(new, "amcb_npi_linkage_FROZEN", date = "2026-09-11", root = vault)),
    "T12 publishing over an existing name with different contents is refused")

cat("\n-- LATEST, FOR INPUTS NO MANIFEST PINS --\n")
a <- tempfile(fileext = ".csv"); writeLines("x\n1", a)
b <- tempfile(fileext = ".csv"); writeLines("x\n2", b)
vault_publish(a, "midwife_practice_locations", date = "2026-08-11", root = vault)
pb <- vault_publish(b, "midwife_practice_locations", date = "2026-09-10", root = vault)
chk(identical(vault_latest("midwife_practice_locations", root = vault), pb),
    "T13 newest by the date in the name")
chk(vault_refuses(vault_latest("dac_facility_affiliations", root = vault)), "T14 a stem with no file stops")

cat("\n-- WHERE --\n")
old <- Sys.getenv("MIDWIFERY_VAULT")
Sys.setenv(MIDWIFERY_VAULT = vault)
chk(identical(vault_root(), normalizePath(vault)), "T15 MIDWIFERY_VAULT wins")
Sys.setenv(MIDWIFERY_VAULT = file.path(tempdir(), "no-such-vault"))
chk(vault_refuses(vault_root()), "T16 a MIDWIFERY_VAULT that does not exist stops rather than falling back")
Sys.setenv(MIDWIFERY_VAULT = old)

cat("\n-- THE CURRENT FREEZE --\n")
man <- tempfile(fileext = ".json")
jsonlite::write_json(list(artifact_sha256 = vault_file_sha(src), artifact_rows = 1L), man, auto_unbox = TRUE)
Sys.setenv(MIDWIFERY_VAULT = vault)
same_file <- function(a, b) identical(normalizePath(a), normalizePath(b))
chk(same_file(vault_linkage_freeze(man, local = file.path(tempdir(), "absent.csv")), dest),
    "T17 no local copy: the vault's copy of the manifest's freeze")
stale <- tempfile(fileext = ".csv"); writeLines("stale", stale)
chk(same_file(vault_linkage_freeze(man, local = stale), dest),
    "T18 a stale local copy is passed over for the verified vault copy")
chk(identical(vault_linkage_freeze(man, local = src), src),
    "T19 a local copy that IS the manifest's freeze is used directly")
Sys.setenv(MIDWIFERY_VAULT = old)

cat(if (fails) sprintf("\nFAILURES (%d)\n", fails) else "\nPASS (0 failures)\n")
quit(status = if (fails) 1L else 0L)
