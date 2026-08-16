#!/usr/bin/env Rscript
# =============================================================================
# The resolver may only claim what its evidence supports
# =============================================================================
# Two layers now feed one table: Medicare arms (PECOS, Care Compare) and
# non-Medicare arms (NPPES co-location, facility, birth-centre registries).
# The value of the second layer is entirely in seeing people the first cannot,
# so the failure that matters is a non-Medicare pair quietly acquiring the
# authority of a Medicare one.
#
# What this pins down:
#
#   N  norm_org() merges corporate suffixes and NOTHING else. It is the only
#      thing joining arms that share no identifier, so an over-merge here
#      invents corroboration across the whole table.
#   C  affiliation_class and currentness_class answer DIFFERENT questions, and
#      neither promotes co-location to a current-affiliation claim.
#   L  evidence_layer identifies what only the non-Medicare layer could produce.
#   K  co-location keys are exact; ambiguity yields no organization.
#   E  nothing is called an employer.
#
# Hermetic. Sources the libraries and reasons about the builders' text; no
# artifact, no warehouse, no network.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({ library(dplyr); library(stringr) })
source(file.path(root, "R", "lib", "org_names.R"))
source(file.path(root, "R", "lib", "organization_affiliation_status.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
RES <- "build_organization_affiliation_resolver.R"
COL <- "build_nppes_colocation_2025.R"
code_of <- function(f) {
  if (!file.exists(f)) return("")
  ln <- readLines(f, warn = FALSE)
  paste(ln[!grepl("^\\s*#", ln)], collapse = "\n")
}

# =============================================================================
cat("\n-- N: norm_org() merges suffixes and nothing else --\n")
# =============================================================================
{
  chk(identical(norm_org("MERCY CLINIC, LLC"), norm_org("Mercy Clinic Inc")),
      "N1 corporate suffix and case differences merge")
  chk(identical(norm_org("St. Mary's Hospital"), norm_org("ST MARYS HOSPITAL")),
      "N2 punctuation differences merge")
  # The over-merge that would fabricate corroboration. These are two real
  # organizations in the cohort's top-affiliation list.
  chk(!identical(norm_org("FAIRVIEW CLINICS"), norm_org("FAIRVIEW HEALTH SERVICES")),
      "N3 same system, different entities do NOT merge")
  chk(!identical(norm_org("WOMENS CARE FLORIDA"), norm_org("FLORIDA WOMAN CARE")),
      "N4 reordered words do NOT merge -- no stemming, no fuzzy matching")
  chk(!identical(norm_org("OB HOSPITALIST GROUP"), norm_org("OB HOSPITALIST GROUP OF TEXAS")),
      "N5 a longer distinct name does NOT merge into a shorter one")
  chk(identical(norm_org(NA), ""),
      "N6 a missing name is '' not NA, so it groups instead of vanishing")
  # An empty key must never become an organization.
  chk(grepl("nzchar\\(org_key\\)", code_of(RES)),
      "N7 the resolver drops rows with no usable organization name")
  # Defined exactly once: two callers, one definition.
  defs <- length(grep("^norm_org <- function",
                      unlist(lapply(list.files(root, pattern = "\\.R$",
                                               recursive = TRUE, full.names = TRUE),
                                    function(p) tryCatch(readLines(p, warn = FALSE),
                                                         error = function(e) character(0)))),
                      value = TRUE))
  chk(defs == 1L, sprintf("N8 norm_org() is defined exactly once in the repo [%d]", defs))
}

# =============================================================================
cat("\n-- C: the two classes answer different questions --\n")
# =============================================================================
{
  code <- code_of(RES)
  chk(grepl("affiliation_class", code) && grepl("currentness_class", code),
      "C1 both classes are produced")
  # Currentness must come from the ruling's own classifier, not a second ladder
  # invented here that could disagree with it.
  chk(grepl("classify_affiliation_status", code),
      "C2 currentness reuses the contract's classifier rather than a new ladder")
  chk(grepl("organization_affiliation_status\\.R", code),
      "C3 and sources it from the canonical library")

  # Co-location, alone, is not a current-affiliation claim. This is the same
  # rule H4 pins for PECOS-only, applied to the non-Medicare layer.
  chk(!is_current_affiliation(classify_affiliation_status(FALSE, FALSE, TRUE)),
      "C4 co-location alone is NOT a current affiliation")
  chk(identical(classify_affiliation_status(FALSE, FALSE, TRUE), "address_only"),
      "C5 and it is labelled for what it is: address_only")
  # Evidence count is a lower bound, so it must never be used to assert absence.
  chk(grepl("multi_source_confirmed", code),
      "C6 multi-source is a named class, not an inferred threshold")
}

# =============================================================================
cat("\n-- L: the non-Medicare layer is identifiable --\n")
# =============================================================================
# The whole point of the second layer is seeing people the first cannot. If
# that cannot be read off the output, the layer cannot be evaluated.
{
  code <- code_of(RES)
  chk(grepl("evidence_layer", code), "L1 evidence_layer is produced")
  chk(grepl("non_medicare_only", code) && grepl("medicare_only", code),
      "L2 with values that separate the layers")
  chk(grepl("both_layers", code),
      "L3 and a value for pairs both layers support")
  # A pair supported by BOTH must not be filed as non-Medicare-only, which
  # would overstate what the new layer bought.
  i_both <- regexpr("both_layers", code)
  i_medonly <- regexpr('"medicare_only"', code)
  chk(i_both > 0 && i_medonly > 0 && i_both < i_medonly,
      "L4 both_layers is tested BEFORE medicare_only, so it cannot be masked")
}

# =============================================================================
cat("\n-- K: co-location keys are exact, ambiguity yields nothing --\n")
# =============================================================================
{
  code <- code_of(COL)
  chk(nzchar(code), "K1 the co-location builder exists")
  if (nzchar(code)) {
    # The prohibition from CLAUDE.md: proximity is not employment.
    chk(!grepl("distance|nearest|st_dwithin|haversine|km", code, ignore.case = TRUE),
        "K2 no distance, nearest-facility or radius rule anywhere")
    chk(grepl("n_org_at_key == 1L", code),
        "K3 only a key matching exactly ONE organization yields a name")
    # Keys must come from the shared library, or the two sides normalise
    # differently and the match means nothing.
    chk(grepl("address_keys\\.R", code),
        "K4 keys come from the canonical library")
    chk(grepl("norm_addr\\(", code) && grepl("phone10\\(", code) &&
        grepl("zip9\\(", code) && grepl("zip5\\(", code),
        "K5 and all four canonical key functions are the ones used")
    chk(grepl("addkeys\\(orgs\\)", code) && grepl("addkeys\\(mw\\)", code),
        "K6 both sides are keyed by the SAME function")
    # A defunct organization is worse than no answer.
    chk(grepl("deact", code) && grepl("react", code),
        "K7 deactivated organizations are excluded, reactivation respected")
    # Strength must be ranked, and ties broken deterministically.
    chk(grepl("STRENGTH", code) && grepl("arrange\\(.*rank", code),
        "K8 the strongest key wins and ties break deterministically")
  }
}

# =============================================================================
cat("\n-- E: nothing is an employer --\n")
# =============================================================================
{
  for (f in c(RES, COL)) {
    code <- code_of(f)
    if (!nzchar(code)) next
    chk(!grepl('"[^"]*employer[^"]*"', code),
        sprintf("E1 no string literal names an employer [%s]", basename(f)))
    chk(!grepl("\\bemployer\\b *(<-|=)", code),
        sprintf("E2 no variable is named employer [%s]", basename(f)))
  }
  chk(grepl("DECISIONS_CONTRACT", paste(readLines(RES, warn = FALSE), collapse = "\n"),
            fixed = TRUE),
      "E3 the resolver points at the ruling it implements")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
