#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

ART <- "artifacts"
DOC <- "docs"
dir.create(DOC, recursive = TRUE, showWarnings = FALSE)

sites <- read_csv(file.path(ART, "midwife_work_sites_summary.csv"), show_col_types = FALSE)
long <- read_csv(file.path(ART, "midwife_work_sites_long.csv"), show_col_types = FALSE)
N <- nrow(sites)

nonmissing <- function(x) {
  if (is.character(x)) sum(!is.na(x) & nzchar(str_squish(x))) else sum(!is.na(x))
}

summary_num <- function(x, digits = 1) {
  x <- x[is.finite(x)]
  if (!length(x)) return(NA_character_)
  sprintf(
    "median %.*f; IQR %.*f-%.*f; range %.*f-%.*f",
    digits, median(x), digits, quantile(x, .25), digits, quantile(x, .75),
    digits, min(x), digits, max(x)
  )
}

max_pairwise_km <- function(d) {
  if (nrow(d) < 2L) return(0)
  pairs <- utils::combn(seq_len(nrow(d)), 2L)
  lat1 <- d$lat[pairs[1, ]] * pi / 180
  lat2 <- d$lat[pairs[2, ]] * pi / 180
  dlat <- (d$lat[pairs[2, ]] - d$lat[pairs[1, ]]) * pi / 180
  dlon <- (d$lon[pairs[2, ]] - d$lon[pairs[1, ]]) * pi / 180
  a <- sin(dlat / 2)^2 + cos(lat1) * cos(lat2) * sin(dlon / 2)^2
  max(2 * 6371.0088 * asin(sqrt(pmin(1, a))), na.rm = TRUE)
}

lower48 <- state.abb
lower48_sites <- long %>%
  filter(state %in% lower48, is.finite(lat), is.finite(lon))
lower48_distance <- lower48_sites %>%
  group_by(certification_number) %>%
  group_modify(~ tibble::tibble(max_lower48_km = max_pairwise_km(.x))) %>%
  ungroup()

rows <- list()
add_row <- function(domain, measure, n_observed, summary = NA_character_,
                    source_artifact, source_fields, percent_n = TRUE) {
  rows[[length(rows) + 1L]] <<- tibble::tibble(
    domain = domain,
    measure = measure,
    n_observed = as.integer(n_observed),
    percent_of_cohort = if (percent_n) round(100 * n_observed / N, 1) else NA_real_,
    summary = summary,
    source_artifact = source_artifact,
    source_fields = source_fields
  )
}

direct_source <- "midwife_work_sites_summary.csv"
derived_source <- "midwife_work_sites_summary.csv + midwife_work_sites_long.csv"

# Direct Trilliant provider-directory fields.
add_row("Direct Trilliant directory", "Named primary practice site",
        nonmissing(sites$top_site_name), source_artifact = direct_source,
        source_fields = "top_site_name")
add_row("Direct Trilliant directory", "Primary-site visit share",
        nonmissing(sites$top_site_visit_share),
        summary_num(100 * sites$top_site_visit_share, 1),
        source_artifact = direct_source, source_fields = "top_site_visit_share")
add_row("Direct Trilliant directory", "Trilliant-reported number of practice sites",
        nonmissing(sites$trilliant_n_practice_sites),
        summary_num(sites$trilliant_n_practice_sites, 0),
        source_artifact = direct_source, source_fields = "trilliant_n_practice_sites")
add_row("Direct Trilliant directory", "Claims-associated primary organization",
        nonmissing(sites$trilliant_primary_org),
        "Directory organization association; not a verified employer relationship",
        source_artifact = direct_source, source_fields = "trilliant_primary_org")

address_fields <- c(
  top_site_street = "Primary site street address",
  top_site_city = "Primary site city",
  top_site_state = "Primary site state",
  top_site_zip = "Primary site ZIP",
  top_site_lat = "Primary site latitude",
  top_site_lon = "Primary site longitude",
  top_site_county_geoid = "Primary site county"
)
for (field in names(address_fields)) {
  add_row("Direct Trilliant directory", address_fields[[field]], nonmissing(sites[[field]]),
          source_artifact = direct_source, source_fields = field)
}

add_row("Direct Trilliant directory", "Primary-site organization type",
        nonmissing(sites$top_site_org_type), source_artifact = direct_source,
        source_fields = "top_site_org_type")
add_row("Direct Trilliant directory", "Primary-site taxonomy",
        nonmissing(sites$top_site_taxonomy), source_artifact = direct_source,
        source_fields = "top_site_taxonomy")

for (value in c(TRUE, FALSE)) {
  add_row("Direct Trilliant directory",
          paste("Claims-directory activity flag:", toupper(as.character(value))),
          sum(sites$trilliant_active %in% value), source_artifact = direct_source,
          source_fields = "trilliant_active")
}

# Derived work-site fields from Trilliant, NPPES, CMS, and organization evidence.
add_row("Derived work-site data", "Number of distinct physical work sites",
        nonmissing(sites$n_distinct_sites), summary_num(sites$n_distinct_sites, 0),
        source_artifact = derived_source, source_fields = "n_distinct_sites")
add_row("Derived work-site data", "Number of counties represented",
        nonmissing(sites$n_distinct_counties), summary_num(sites$n_distinct_counties, 0),
        source_artifact = derived_source, source_fields = "n_distinct_counties")
add_row("Derived work-site data", "Maximum geographic distance between lower-48 sites (miles)",
        nonmissing(lower48_distance$max_lower48_km),
        summary_num(lower48_distance$max_lower48_km * 0.6213711922, 1),
        source_artifact = derived_source,
        source_fields = "state; lat; lon; certification_number")

indicator_rows <- c(
  any_hospital = "Hospital work-site indicator",
  any_clinic = "Clinic/practice work-site indicator",
  any_fqhc = "FQHC/community-health work-site indicator",
  any_birth_center = "Birth-center work-site indicator"
)
for (field in names(indicator_rows)) {
  add_row("Derived work-site data", indicator_rows[[field]], sum(sites[[field]] %in% TRUE),
          source_artifact = derived_source, source_fields = field)
}
other_facility <- str_detect(coalesce(sites$setting_combination, ""), "other_facility")
add_row("Derived work-site data", "Other-facility work-site indicator", sum(other_facility),
        "Derived when the setting combination includes other facility",
        source_artifact = derived_source, source_fields = "setting_combination")

add_row("Derived work-site data", "Hospital names resolved", nonmissing(sites$hospital_names),
        source_artifact = derived_source, source_fields = "hospital_names")
add_row("Derived work-site data", "Hospital CCNs resolved", nonmissing(sites$top_site_ccn),
        source_artifact = derived_source,
        source_fields = "top_site_ccn; top_site_ccn_basis")
add_row("Derived work-site data", "Strict hospital + birth-center practice",
        sum(sites$blended_strict %in% TRUE),
        "Both strict hospital and strict birth-center evidence present",
        source_artifact = derived_source, source_fields = "blended_strict")
add_row("Derived work-site data", "Broad hospital + birth-center practice",
        sum(sites$blended_broad %in% TRUE),
        "Both broad hospital and broad birth-center evidence present",
        source_artifact = derived_source, source_fields = "blended_broad")

rurality <- sites %>%
  count(rurality_nppes_vs_claims, name = "n") %>%
  filter(!is.na(rurality_nppes_vs_claims), rurality_nppes_vs_claims != "")
for (i in seq_len(nrow(rurality))) {
  add_row("Derived work-site data",
          paste("Rurality comparison:", rurality$rurality_nppes_vs_claims[[i]]),
          rurality$n[[i]],
          "Comparison of NPPES address rurality with claims-site rurality",
          source_artifact = derived_source,
          source_fields = "rurality_nppes_vs_claims")
}

multi_address <- long %>%
  filter(!is.na(n_orgs_at_address), n_orgs_at_address > 1) %>%
  distinct(certification_number)
add_row("Derived work-site data", "Midwives with multiple organizations at a work-site address",
        nrow(multi_address),
        "Co-location signal; does not establish employment or affiliation",
        source_artifact = derived_source, source_fields = "n_orgs_at_address")

out <- bind_rows(rows)
csv_path <- file.path(ART, "table_trilliant_worksite_detail.csv")
md_path <- file.path(DOC, "table_trilliant_worksite_detail.md")
html_path <- file.path(DOC, "table_trilliant_worksite_detail.html")
write_csv(out, csv_path, na = "NA")

header <- c(
  "# Detailed Trilliant and Derived Work-Site Table", "",
  paste0("Cohort denominator: ", format(N, big.mark = ","), " midwives."), "",
  "Counts are midwives with an observed value unless the row is explicitly a category. Percentages use the full cohort denominator. Direct directory fields are separated from derived work-site fields. Organization co-location is an address-level signal and is not evidence of employment.", "",
  "| Domain | Measure | n observed | % of cohort | Summary | Source artifact | Source field(s) |",
  "|:--|:--|--:|--:|:--|:--|:--|"
)
escape_md <- function(x) str_replace_all(ifelse(is.na(x), "NA", as.character(x)), "\\|", "\\\\|")
body <- apply(out, 1, function(r) paste0("| ", paste(escape_md(r), collapse = " | "), " |"))
writeLines(c(header, body), md_path)

pandoc <- Sys.which("pandoc")
if (nzchar(pandoc)) {
  system2(pandoc, c(shQuote(md_path), "-o", shQuote(html_path), "--standalone", "--quiet"))
} else {
  warning("pandoc not found; Markdown was written but HTML was not rendered")
}

message("Wrote ", csv_path, ", ", md_path, ", and ", html_path)
