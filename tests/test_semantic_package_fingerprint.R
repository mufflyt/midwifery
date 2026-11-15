#!/usr/bin/env Rscript
# =============================================================================
# A result's provenance must record the package versions that DEFINE it
# =============================================================================
# THE INCIDENT (2026-11-14). The AMCB-NPPES linkage was frozen on 2026-09-10
# (sha256 1a7bd6a8) and re-frozen on 2026-10-22 (9f224007). Between them, 1,278
# normalised middle names and 129 normalised given names changed -- "B." became
# "B", "SR." became "SR" -- on byte-identical roster input, and three
# certification records changed study-cohort membership as a result.
#
# Nothing in this repository had changed. mysterynpi::split_given() had begun
# stripping periods and commas (commit cb86e56, 2026-09-13), which is the
# CORRECT rule. The defect was that no artifact recorded which build of the
# matcher produced it, so `code_sha256` -- this repo's own code, by content --
# was identical across two freezes that meant different things.
#
# Establishing that took comparing frozen CSVs across two machines over
# Tailscale. These assertions exist so the next such change is a field in a
# JSON file instead.
#
# Run:  Rscript tests/test_semantic_package_fingerprint.R
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root)                     # artifact_provenance.R sources by relative path
on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages(source(file.path("R", "lib", "artifact_provenance.R")))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

cat("\n-- the declaration --\n")

# T1. mysterynpi owns name_key(), split_given(), middle_tokens() and
# middle_agreement(). If it is ever dropped from this vector, the incident
# above becomes unreconstructible again.
chk("mysterynpi" %in% SEMANTIC_PACKAGES,
    "T1 mysterynpi is declared semantic -- it owns the name-matching rules")

# T2. Declared, not discovered: a short, auditable list. A fingerprint over
# every loaded namespace would churn every sidecar on an unrelated upgrade.
chk(length(SEMANTIC_PACKAGES) >= 1L && length(SEMANTIC_PACKAGES) <= 12L &&
      !anyDuplicated(SEMANTIC_PACKAGES),
    "T2 the declaration is short, deduplicated and hand-maintained")

cat("\n-- what .semantic_pkgs() reports --\n")

got <- .semantic_pkgs()

# T3. One entry per declared package, in declaration order, and never a
# silently shortened list.
chk(length(got) == length(SEMANTIC_PACKAGES) &&
      identical(vapply(got, `[[`, character(1), "package"), SEMANTIC_PACKAGES),
    "T3 one entry per declared package, in order")

# T4. Every installed package reports a version. A version-less entry would
# record that we looked and learned nothing, which is the status quo it
# replaces.
inst <- Filter(function(e) isTRUE(e$installed), got)
chk(length(inst) > 0L &&
      all(vapply(inst, function(e) is.character(e$version) && nzchar(e$version), logical(1))),
    "T4 every installed package reports a non-empty version")

# T5. A GitHub-installed package reports its source commit. This is the field
# that would have answered "which matcher built this freeze?" in one look.
mn <- Filter(function(e) identical(e$package, "mysterynpi"), got)[[1]]
chk(isTRUE(mn$installed) && "source_sha" %in% names(mn),
    "T5 mysterynpi carries a source_sha field (the commit, when installed from git)")

# T6. CRAN packages have no RemoteSha. NA is the honest answer -- the version
# alone identifies a CRAN source -- and must not be the string "NULL" or "".
chk(all(vapply(inst, function(e)
        is.na(e$source_sha) || (is.character(e$source_sha) && nzchar(e$source_sha) &&
                                !identical(e$source_sha, "NULL")), logical(1))),
    "T6 a CRAN package reports source_sha = NA, not an empty or 'NULL' string")

cat("\n-- absence is reported, not omitted --\n")

# T7. A package that is not installed must appear with installed = FALSE.
# Omitting it would make "absent" and "never asked" look identical in the
# sidecar, which is the ambiguity this whole mechanism exists to remove.
ghost <- .semantic_pkgs(c("mysterynpi", "aPackageThatDoesNotExist"))
chk(length(ghost) == 2L &&
      identical(ghost[[2]]$package, "aPackageThatDoesNotExist") &&
      isFALSE(ghost[[2]]$installed),
    "T7 an uninstalled package is reported as installed = FALSE, not dropped")

# T8. ...and reporting it must not invent a version for it.
chk(!("version" %in% names(ghost[[2]])),
    "T8 an uninstalled package carries no fabricated version")

cat("\n-- it reaches the sidecar --\n")

tmp <- file.path(tempdir(), "semantic_fingerprint_probe.csv")
side <- paste0(tmp, ".provenance.json")
unlink(c(tmp, side))
write_with_provenance(data.frame(a = 1:2), tmp)
m <- jsonlite::read_json(side)

# T9. The field is actually written. The helper being correct is worth nothing
# if write_with_provenance() does not call it.
chk("semantic_packages" %in% names(m) && length(m$semantic_packages) == length(SEMANTIC_PACKAGES),
    "T9 write_with_provenance() emits semantic_packages into the sidecar")

# T10. mysterynpi's version is readable from the sidecar without re-running
# anything -- the actual requirement.
sp <- m$semantic_packages
mn_side <- Filter(function(e) identical(e$package, "mysterynpi"), sp)
chk(length(mn_side) == 1L && nzchar(as.character(mn_side[[1]]$version)),
    "T10 the sidecar states which mysterynpi version produced the artifact")

# T11. The existing required-key schema still passes. ci_data_regression_guard.R
# uses setdiff(need, names(m)), so a NEW key is additive -- but that is a fact
# about the gate today, and this pins it rather than assuming it.
chk(length(setdiff(c("artifact", "written_utc", "inputs"), names(m))) == 0L,
    "T11 the sidecar still satisfies the R provenance schema (additive, not breaking)")

# T12. The two fingerprints answer different questions and must both survive:
# code_sha256 says which of OUR code ran, semantic_packages says which rules it
# called. The incident is precisely the case where the first is unchanged and
# the second is not.
chk(all(c("code_sha256", "code", "semantic_packages") %in% names(m)),
    "T12 code fingerprint and semantic-package fingerprint coexist")

unlink(c(tmp, side))

cat(sprintf("\n%s (%d failure(s))\n", if (fails == 0L) "PASS" else "FAILED", fails))
if (fails > 0L) quit(status = 1L)
