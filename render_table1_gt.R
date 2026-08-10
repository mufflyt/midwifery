#!/usr/bin/env Rscript
# =============================================================================
# Table 1 rendered with gt, using the canonical manuscript styler
# =============================================================================
# There is no `ggtable` function anywhere in this ecosystem -- no ggtexttable,
# tableGrob or ggtable call exists in isochrones, mysterymaps, cliff, twostep,
# mufflyaccess or simulation. What DOES exist are two canonical renderers:
#
#   gtsummary::tbl_summary -> flextable -> .docx
#       manuscript/R/create_table1_physician_characteristics.R
#       cliff/code/07_create_table1.R
#   gt::gt() %>% style_gt_table()
#       manuscript/R/create_table1_sample_characteristics.R
#
# This uses the SECOND, for one reason: `tbl_summary()` recomputes a table from
# person-level data, and every hard-won decision in Table 1 lives in the
# aggregation rather than in the raw rows --
#
#   * registry rows use N = 11,913 while Healthgrades rows use 11,801, because
#     112 midwives share a profile URL and cannot be attributed one;
#   * ACOG percentages exclude military and territory addresses on their own
#     line rather than folding them into "Unknown";
#   * language is a FLOOR against the eligible denominator, not a proportion,
#     because an absent language means "not listed", not "English only";
#   * a CONSTANT field (hg_years_experience) is barred at any coverage.
#
# Handing the cohort to tbl_summary() would silently discard all four and emit
# a table that looks conventional and states different things. So the
# already-aggregated artifact is rendered, and the canonical STYLER is reused
# so the output matches the manuscript's other tables.
#
# Input : artifacts/table1_midwives.csv  (long: characteristic/n/percent/category)
# Output: docs/table1_midwives_gt.html, docs/table1_midwives_gt.docx
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(gt)
})

root <- normalizePath(".")
t1 <- read_csv(file.path(root, "artifacts", "table1_midwives.csv"),
               show_col_types = FALSE, progress = FALSE)

prov <- file.path(root, "artifacts", "table1_provenance.csv")
stamp <- if (file.exists(prov)) read_csv(prov, show_col_types = FALSE, progress = FALSE) else NULL

# Canonical styler from mufflyt/isochrones. Sourced through a path dependency
# that fails loudly, the pattern used elsewhere in this repo -- not copied,
# because a second copy is a second thing to drift.
iso <- Sys.getenv("ISOCHRONES_HOME", path.expand("~/isochrones"))
utils_path <- file.path(iso, "manuscript", "R", "00_manuscript_utils.R")
have_styler <- FALSE
if (file.exists(utils_path)) {
  local({
    owd <- setwd(iso); on.exit(setwd(owd), add = TRUE)
    suppressWarnings(suppressMessages(
      try(sys.source(file.path("manuscript", "R", "00_manuscript_utils.R"),
                     envir = globalenv()), silent = TRUE)))
  })
  have_styler <- exists("style_gt_table", mode = "function")
}
if (!have_styler) {
  stop(sprintf(paste0("style_gt_table() not found. It is the canonical gt styler ",
                      "in mufflyt/isochrones at manuscript/R/00_manuscript_utils.R ",
                      "(looked under %s). Set ISOCHRONES_HOME, or fix the path -- ",
                      "do not restyle locally, which is how two looks diverge."),
              iso), call. = FALSE)
}

# gt renders group headers from a grouping column, so the category rows that
# the markdown emits as bold pseudo-rows are dropped here and re-expressed as
# real row groups. Same content, correct structure.
tab <- t1 %>%
  filter(!is.na(characteristic)) %>%
  transmute(
    Category = category,
    Characteristic = characteristic,
    n = ifelse(is.na(n), NA_integer_, as.integer(n)),
    `%` = percent
  )

n_cohort <- t1 %>% filter(characteristic == "ACTIVE, primary-linked midwives") %>% pull(n)
sub <- sprintf("%s ACTIVE primary-linked midwives%s",
               format(n_cohort, big.mark = ","),
               if (!is.null(stamp))
                 sprintf(" · built %s", stamp$built_at[1]) else "")

gt_tab <- tab %>%
  gt(groupname_col = "Category", rowname_col = "Characteristic") %>%
  style_gt_table(title = "Table 1. Characteristics of the ACTIVE certified-midwife cohort",
                 subtitle = sub) %>%
  fmt_number(columns = "n", decimals = 0, use_seps = TRUE) %>%
  fmt_number(columns = "%", decimals = 1) %>%
  sub_missing(columns = c("n", "%"), missing_text = "—") %>%
  cols_align(align = "right", columns = c("n", "%")) %>%
  tab_style(style = cell_text(weight = "bold"),
            locations = cells_row_groups()) %>%
  tab_source_note(md(paste0(
    "Registry-derived rows use the full cohort. **Healthgrades-derived rows use a ",
    "smaller denominator**: midwives sharing a profile URL with another certificant ",
    "cannot be attributed one and are excluded from those rows only. Language is a ",
    "**floor**, not a proportion — an absent language means *not listed*, not ",
    "*English only*. `hg_years_experience` is withheld at any coverage because it is ",
    "constant (0 on every profile). Healthgrades age describes profile-holders and ",
    "runs ~8 years above WA licensing and ~13 above OH voter registration; the ",
    "calibrated age block covers the whole cohort."))) %>%
  tab_source_note(md(paste0(
    "Source: AMCB roster linked to NPPES; RUCC 2023; ACOG district crosswalk; ",
    "Healthgrades profile scrape.")))

dir.create(file.path(root, "docs"), showWarnings = FALSE)
gtsave(gt_tab, file.path(root, "docs", "table1_midwives_gt.html"))
cat("written: docs/table1_midwives_gt.html\n")

ok <- tryCatch({
  gtsave(gt_tab, file.path(root, "docs", "table1_midwives_gt.docx")); TRUE
}, error = function(e) { message("docx not written: ", conditionMessage(e)); FALSE })
if (ok) cat("written: docs/table1_midwives_gt.docx\n")
