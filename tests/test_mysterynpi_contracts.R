# =============================================================================
# The mysterynpi contracts, asserted from the CONSUMER side
# =============================================================================
#
# This is the mechanism the 2026-09 migration was for. This pipeline now
# delegates its name handling to the mysterynpi package, and these assertions
# pin the BEHAVIOUR it relies on -- not the signatures, the behaviour. Each
# assert_*_contract() below is written by the package so that it can also be
# run against a stand-in and demonstrably fail; a change upstream that flips
# any of them fails HERE, in this repository's CI, before it can touch a
# cohort. That is the difference between depending on a package and
# source()-ing a path: Cycle 4's path moved silently, a contract cannot.
#
# Runs in the nightly like every tests/test*.R. Requires mysterynpi, so it is
# registered external-private in ci_nightly_exceptions.txt alongside the other
# tests that need it.
# =============================================================================

if (!requireNamespace("mysterynpi", quietly = TRUE)) {
  stop("mysterynpi is required: remotes::install_github(\"mufflyt/mysterynpi@v0.2.0\")",
       call. = FALSE)
}
if (utils::packageVersion("mysterynpi") < "0.2.0") {
  stop("this pipeline pins mysterynpi >= 0.2.0; installed: ",
       utils::packageVersion("mysterynpi"), call. = FALSE)
}
suppressMessages(library(mysterynpi))

checks <- 0L
chk <- function(ok, what) {
  if (!isTRUE(ok)) stop("CONTRACT FAILED: ", what, call. = FALSE)
  checks <<- checks + 1L
  cat("ok:", what, "\n")
}

chk(assert_middle_agreement_contract(),  "middle agreement (position, initials, no fuzz, absence)")
chk(assert_gender_agreement_contract(),  "gender veto (encodings, numerics refused, absence)")
chk(assert_nickname_agreement_contract(),"nickname one-hop (no transitive closure)")
chk(assert_suffix_agreement_contract(),  "generational suffixes (JR/SR veto, JR==II)")
chk(assert_license_agreement_contract(), "license (state-scoped, cannot veto)")
chk(assert_surname_agreement_contract(), "surname (components, maiden-as-middle rescue)")

# The properties THIS cohort additionally leans on, asserted directly:
chk(identical(SURNAME_PARTICLES[1:3], c("DE", "DEL", "DELA")) &&
      length(SURNAME_PARTICLES) == 33L,
    "surname particle list is the one the crosswalk was built with")
chk(identical(MIN_SURNAME_TOKEN, 4L),
    "surname token floor is 4 (2 lets particles become blocking keys)")
chk(all(c("CNM", "CM", "APRN", "IBCLC", "FACNM") %in% NAME_NOISE),
    "midwifery credentials are still stripped as noise")
chk(identical(name_key("Álvarez"), "ALVAREZ"),
    "accents reach their unaccented registry spelling")
chk(identical(split_given("Julie Ann")$given, "JULIE"),
    "the fused AMCB first field still splits at the first token")

# A contract that cannot fail is indistinguishable from one that always
# passes; prove the machinery can refuse a wrong implementation.
always_agree <- function(a, b) rep("corroborates", length(a))
refused <- inherits(try(assert_middle_agreement_contract(always_agree),
                        silent = TRUE), "try-error")
chk(refused, "the contract machinery rejects a stand-in that always agrees")

if (checks < 12L) {
  stop(sprintf("only %d contract checks ran; the file has decayed", checks),
       call. = FALSE)
}
cat(sprintf("PASS test_mysterynpi_contracts: %d checks, mysterynpi %s\n",
            checks, utils::packageVersion("mysterynpi")))
