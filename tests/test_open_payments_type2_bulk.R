#!/usr/bin/env Rscript
# =============================================================================
# Regression tests for resolve_type2_bulk()
# =============================================================================
# Each test reproduces a specific behaviour of the replaced implementation and
# asserts the corrected one does not share it. The old path is simulated here
# (old_api_style_match) so the tests are shown to DISCRIMINATE -- a test that
# passes against both implementations proves nothing.
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(stringr); library(tibble) })
source("link_open_payments_type2_bulk.R")

FAILS <- character(0)
ok <- function(name, cond) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", name))
  else { FAILS <<- c(FAILS, name); cat(sprintf("  FAIL  %s\n", name)) }
}

#' The replaced behaviour: alphabetical order, limit 10, 8-char substring,
#' first passing candidate. Used only to prove the tests discriminate.
old_api_style_match <- function(addr, zip, org_df, limit = 10L) {
  cands <- org_df %>% filter(op_zip5(zip) == op_zip5(.env$zip)) %>%
    arrange(organization_name) %>% head(limit)
  a_clean <- op_norm_addr(addr)
  for (i in seq_len(nrow(cands))) {
    a1 <- op_norm_addr(cands$addr[i])
    if (is.na(a1) || is.na(a_clean)) next
    # Python's `in` is substring-ANYWHERE, not a prefix test. Simulating it
    # with str_starts() understated the old path and made two discrimination
    # checks pass for the wrong reason.
    if (str_detect(a1, fixed(substr(a_clean, 1, 8))) ||
        str_detect(a_clean, fixed(substr(a1, 1, 8))))
      return(cands$organization_name[i])   # first passing candidate wins
  }
  NA_character_
}

# --- fixture: a dense ZIP, correct organization late in the alphabet ---------
dense <- tibble(
  type2_npi = sprintf("1%09d", 1:30),
  organization_name = c(sprintf("A%02d ANESTHESIA GROUP", 1:12),
                        sprintf("B%02d BILLING LLC", 1:8),
                        sprintf("C%02d CLINIC", 1:9),
                        "ZENITH WOMENS HEALTH MIDWIFERY"),
  addr = c(rep("999 OTHER ST", 29), "100 MAIN ST"),
  zip  = rep("44106", 30))

cat("=== dense ZIP: correct org sorts AFTER the first 10 ===\n")
r <- resolve_type2_bulk(tibble(id = "m1", addr = "100 MAIN ST", zip = "44106"), dense)
ok("resolves to the correct late-alphabet organization",
   r$status == "unique_exact" && r$organization_name == "ZENITH WOMENS HEALTH MIDWIFERY")
old <- old_api_style_match("100 MAIN ST", "44106", dense)
ok("tests discriminate: old path did NOT return it",
   is.na(old) || old != "ZENITH WOMENS HEALTH MIDWIFERY")
cat(sprintf("        (old path returned: %s)\n", if (is.na(old)) "no match" else old))

cat("\n=== street-number prefix collisions ===\n")
o2 <- tibble(type2_npi = "1000000001", organization_name = "HOSPITAL A",
             addr = "100 MAIN ST", zip = "10001")
r <- resolve_type2_bulk(tibble(id = "m", addr = "2100 MAIN ST", zip = "10001"), o2)
ok("100 MAIN ST must not match 2100 MAIN ST", r$status == "no_match")
ok("tests discriminate: old path DID match it",
   !is.na(old_api_style_match("2100 MAIN ST", "10001", o2)))

o3 <- tibble(type2_npi = "1000000002", organization_name = "HOSPITAL B",
             addr = "1 PARK AVE", zip = "10001")
r <- resolve_type2_bulk(tibble(id = "m", addr = "11 PARK AVE", zip = "10001"), o3)
ok("1 PARK AVE must not match 11 PARK AVE", r$status == "no_match")
ok("tests discriminate: old path DID match it",
   !is.na(old_api_style_match("11 PARK AVE", "10001", o3)))

cat("\n=== ambiguity is preserved, never collapsed ===\n")
multi <- tibble(type2_npi = c("1000000010", "1000000011", "1000000012"),
                organization_name = c("ALPHA CLINIC", "MIDDLE GROUP", "ZETA WOMENS CARE"),
                addr = rep("500 SHARED BLVD", 3), zip = rep("60601", 3))
r <- resolve_type2_bulk(tibble(id = "m", addr = "500 SHARED BLVD", zip = "60601"), multi)
ok("three organizations at one address -> multiple_plausible",
   r$status == "multiple_plausible" && r$n_candidates == 3)
ok("no organization is emitted when ambiguous", is.na(r$organization_name))
ok("alphabetically first is NOT silently chosen",
   is.na(r$organization_name) || r$organization_name != "ALPHA CLINIC")

cat("\n=== one defensible candidate resolves uniquely ===\n")
r <- resolve_type2_bulk(tibble(id = "m", addr = "500 SHARED BLVD", zip = "60601"),
                        multi[2, ])
ok("single exact candidate -> unique_exact",
   r$status == "unique_exact" && r$organization_name == "MIDDLE GROUP")

cat("\n=== no candidate stays unmatched, never an arbitrary organization ===\n")
r <- resolve_type2_bulk(tibble(id = "m", addr = "742 EVERGREEN TER", zip = "60601"), multi)
ok("no match -> no_match with no organization",
   r$status == "no_match" && is.na(r$organization_name))

cat("\n=== ORDER INVARIANCE (the contract the old path violated) ===\n")
set.seed(11)
base_in <- tibble(id = c("m1", "m2", "m3"),
                  addr = c("100 MAIN ST", "500 SHARED BLVD", "742 EVERGREEN TER"),
                  zip  = c("44106", "60601", "60601"))
orgs <- bind_rows(dense, multi)
canon <- resolve_type2_bulk(base_in, orgs) %>% arrange(id)
same <- TRUE
for (i in 1:8) {
  ro <- orgs[sample(nrow(orgs)), ]
  ri <- base_in[sample(nrow(base_in)), ]
  got <- resolve_type2_bulk(ri, ro) %>% arrange(id)
  if (!identical(canon$status, got$status) ||
      !identical(canon$organization_name, got$organization_name) ||
      !identical(canon$n_candidates, got$n_candidates)) same <- FALSE
}
ok("organization-table and input reordering do not change the answer (8 shuffles)", same)

# The old path is order-dependent by construction: reordering the organization
# table changes which candidates survive head(limit).
old_a <- old_api_style_match("100 MAIN ST", "44106", dense)
old_b <- old_api_style_match("100 MAIN ST", "44106", dense[sample(nrow(dense)), ])
ok("tests discriminate: old path is order-dependent OR truncates the answer away",
   !identical(old_a, old_b) || is.na(old_a) || old_a != "ZENITH WOMENS HEALTH MIDWIFERY")

cat("\n=== ALIAS DETERMINISM: one NPI, one address, two names ===\n")
# The resolver used distinct(..., .keep_all = TRUE), which retained whichever
# organization_name appeared FIRST. The NPI stayed stable but the emitted name
# could change with row order -- a silent breach of order invariance.
alias <- tibble(
  type2_npi = c("1000000030", "1000000030"),
  organization_name = c("ZED WOMENS HEALTH", "ALPHA WOMENS HEALTH"),
  addr = c("77 ALIAS WAY", "77 ALIAS WAY"), zip = c("30301", "30301"))
in1 <- tibble(id = "m", addr = "77 ALIAS WAY", zip = "30301")
r1 <- resolve_type2_bulk(in1, alias)
r2 <- resolve_type2_bulk(in1, alias[c(2, 1), ])
ok("one NPI with two aliases still resolves uniquely",
   r1$status == "unique_exact" && r1$n_candidates == 1)
ok("emitted name is identical under organization-row reordering",
   identical(r1$organization_name, r2$organization_name))
ok("both aliases are preserved, none silently dropped",
   grepl("ALPHA WOMENS HEALTH", r1$organization_name, fixed = TRUE) &&
   grepl("ZED WOMENS HEALTH", r1$organization_name, fixed = TRUE))
ok("full emitted row is identical under reordering", identical(r1, r2))

cat("\n=== INPUT CONTRACT: duplicate ids must fail loudly ===\n")
dupin <- tibble(id = c("m", "m"), addr = c("1 A ST", "2 B ST"),
                zip = c("30301", "30301"))
err <- tryCatch({ resolve_type2_bulk(dupin, alias); NA_character_ },
                error = function(e) conditionMessage(e))
ok("two addresses for one id raises an error rather than pooling",
   !is.na(err) && grepl("more than one", err))
ok("the error names the offending id", !is.na(err) && grepl("\\bm\\b", err))

cat("\n=== normalization equivalences still resolve ===\n")
o4 <- tibble(type2_npi = "1000000020", organization_name = "MERCY WOMENS",
             addr = "100 MAIN STREET", zip = "10001")
r <- resolve_type2_bulk(tibble(id = "m", addr = "100 MAIN ST", zip = "10001"), o4)
ok("STREET vs ST resolves", r$status == "unique_exact")

cat("\n=== ZIP participates: same street in a different ZIP must not match ===\n")
r <- resolve_type2_bulk(tibble(id = "m", addr = "100 MAIN ST", zip = "99999"), o4)
ok("different ZIP -> no_match", r$status == "no_match")

cat("\n=== empty / missing addresses never resolve ===\n")
r <- resolve_type2_bulk(tibble(id = c("a","b"), addr = c("", NA), zip = c("10001","10001")), o4)
ok("blank and NA addresses -> no_match", all(r$status == "no_match"))

cat("\n=== production fallback policy ===\n")
resolver_src <- paste(readLines("resolve_org_ambiguity.R", warn = FALSE), collapse = "\n")
ok("Open Payments-only fallback is wired as weak evidence",
   grepl("open_payments_only_unique_address", resolver_src, fixed = TRUE) &&
     grepl('affiliation_confidence = "weak"', resolver_src, fixed = TRUE))
ok("Open Payments fallback excludes NPIs already resolved by stronger sources",
   grepl("anti_join\\(resolved_strongish, by = \"npi\"\\)", resolver_src))
ok("Open Payments fallback is assembled after stronger tiers",
   grepl("bind_rows\\(resolved_A, tierB, tierD, tierF\\)", resolver_src))

cat("\n")
if (length(FAILS)) {
  cat(sprintf("FAILED: %d\n", length(FAILS)))
  for (f in FAILS) cat("  - ", f, "\n")
  quit(status = 1)
}
cat("All resolve_type2_bulk() tests passed.\n")
