#!/usr/bin/env Rscript
#' Build observed birth-attendance activity for AMCB midwives
#'
#' @description
#' Adds an observed clinical-activity layer to the AMCB-certified midwifery
#' cohort. It does not replace the roster and does not alter cohort membership.
#'
#' Certification answers: "Is this person an AMCB certificant?"
#' Geography answers:     "Where is this certificant located?"
#' This layer answers:    "Did we OBSERVE this midwife attending births, how
#'                         many, where, and how much effective birth-attending
#'                         supply does that represent?"
#'
#' @section Absence is not zero:
#' A midwife missing from claims or vital records is NOT recorded as having
#' attended zero births. She is recorded as `birth_activity_unobserved` unless
#' her state-year-source is explicitly declared adequately ascertained. This is
#' the same discipline the repository already applies to suppressed CDC WONDER
#' cells and to CMS provider-years below 11 beneficiaries, and it is the whole
#' point of the ascertainment table: without it, "we did not look here" and
#' "she attended no births" become the same number, and every county with poor
#' data reporting would appear to have an inactive workforce.
#'
#' @section Three activity states:
#' \describe{
#'   \item{observed_birth_attendant}{births observed; `birth_active = TRUE`}
#'   \item{no_observed_births}{none observed AND ascertainment declared
#'     adequate; `birth_active = FALSE`}
#'   \item{birth_activity_unobserved}{none observed and ascertainment NOT
#'     established; `birth_active = NA`, `observed_births = NA`}
#' }
#'
#' @param roster_path Path to the AMCB/NPI/geography roster (frozen artifact).
#' @param taf_path Optional normalized TAF delivery file.
#' @param birth_cert_path Optional normalized birth-certificate file.
#' @param ascertainment_path State-year-source ascertainment table.
#' @param county_base_path County covariates including GEOID and rurality.
#' @param activity_year [integer(1)] analysis year.
#' @param save_dir Directory in which artifacts will be written.
#' @param reference_births Birth volume corresponding to 1.0 birth FTE.
#' @param active_status AMCB statuses included in the active cohort.
#'
#' @return A named list: provider activity, location activity, county effective
#'   supply, validation statistics, activity-state counts, and saved paths.
#' @export

# write_with_provenance() and prov_inputs(), the same way stage 13 loads them.
# Guarded so sourcing this file twice, or after another stage, is harmless.
if (!exists("write_with_provenance", mode = "function")) {
  source(file.path("R", "lib", "artifact_provenance.R"))
}

build_midwife_birth_activity <- function(
    roster_path,
    taf_path = NULL,
    birth_cert_path = NULL,
    ascertainment_path,
    county_base_path,
    activity_year,
    save_dir = "artifacts",
    reference_births = 100,
    active_status = "ACTIVE") {

  message("build_midwife_birth_activity(): starting.")
  message("Roster: ", normalizePath(roster_path, mustWork = FALSE))
  message("TAF: ", taf_path %||% "<not supplied>")
  message("Birth certificates: ", birth_cert_path %||% "<not supplied>")
  message("Ascertainment table: ",
          normalizePath(ascertainment_path, mustWork = FALSE))
  message("County base: ", normalizePath(county_base_path, mustWork = FALSE))
  message("Activity year: ", activity_year)
  message("Reference births/FTE: ", reference_births)

  required_files <- c(roster_path, ascertainment_path, county_base_path)
  missing_files <- required_files[!file.exists(required_files)]
  if (length(missing_files) > 0L)
    stop("Missing required file(s): ",
         paste(missing_files, collapse = ", "), call. = FALSE)

  if (is.null(taf_path) && is.null(birth_cert_path))
    stop("Supply at least one activity source: TAF or birth certificates.",
         call. = FALSE)
  if (!is.null(taf_path) && !file.exists(taf_path))
    stop("TAF file does not exist: ", taf_path, call. = FALSE)
  if (!is.null(birth_cert_path) && !file.exists(birth_cert_path))
    stop("Birth-certificate file does not exist: ", birth_cert_path,
         call. = FALSE)

  dir.create(save_dir, recursive = TRUE, showWarnings = FALSE)
  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  message("Reading AMCB-linked roster.")
  roster_raw <- readr::read_csv(roster_path, show_col_types = FALSE,
                                progress = FALSE)
  message("Roster rows: ", fmt_n(nrow(roster_raw)))

  roster_names <- names(roster_raw)
  npi_col    <- find_first_column(roster_names,
                                  c("npi", "NPI", "provider_npi"))
  status_col <- find_first_column(roster_names,
                                  c("status", "certification_status",
                                    "amcb_status"))
  county_col <- find_first_column(roster_names,
                                  c("county_best", "county_exact", "GEOID",
                                    "geoid", "county_fips"))
  if (is.na(npi_col))
    stop("Could not identify the NPI column in the roster.", call. = FALSE)
  if (is.na(status_col))
    stop("Could not identify AMCB certification status.", call. = FALSE)

  message("Defining AMCB-active, NPI-linked cohort.")
  active_roster <- roster_raw |>
    dplyr::mutate(
      npi_activity = normalize_npi(.data[[npi_col]]),
      amcb_status_activity = toupper(trimws(as.character(.data[[status_col]])))
    )
  # The county column is OPTIONAL. Referencing .data[[county_col]] when
  # county_col is NA errors before any if_else() can guard it, so the branch
  # has to happen outside the data mask.
  active_roster$roster_county_fips <- if (!is.na(county_col)) {
    normalize_fips(active_roster[[county_col]])
  } else {
    NA_character_
  }
  active_roster <- active_roster |>
    dplyr::filter(.data$amcb_status_activity %in% toupper(active_status),
                  !is.na(.data$npi_activity))

  # Cohort membership comes from the repository contract, never from a
  # hard-coded N. Certification status and NPI linkage are separate facts and
  # linkage rates differ sharply by status.
  if ("linkage_tier" %in% names(active_roster) &&
      exists("is_cohort_member", mode = "function")) {
    message("Applying repository cohort-membership contract.")
    active_roster <- active_roster |>
      dplyr::filter(is_cohort_member(npi = .data$npi_activity,
                                     linkage_tier = .data$linkage_tier))
  }

  duplicate_npis <- active_roster |>
    dplyr::count(.data$npi_activity, name = "n") |>
    dplyr::filter(.data$n > 1L)
  if (nrow(duplicate_npis) > 0L)
    stop("The active analytic roster contains ", fmt_n(nrow(duplicate_npis)),
         " duplicated NPIs. Resolve identity before activity linkage.",
         call. = FALSE)
  message("Active NPI-linked cohort: ", fmt_n(nrow(active_roster)))

  message("Reading state-year-source ascertainment table.")
  ascertainment_raw <- readr::read_csv(ascertainment_path,
                                       show_col_types = FALSE,
                                       progress = FALSE)
  # npi_completeness is optional. It must be tested on the object ALREADY read,
  # not on the object being defined -- referring to `ascertainment` inside its
  # own transmute() is a self-reference and errors.
  required_asc <- c("state", "year", "source", "adequate_ascertainment")
  missing_asc <- setdiff(required_asc, names(ascertainment_raw))
  if (length(missing_asc) > 0L)
    stop("Ascertainment table is missing: ",
         paste(missing_asc, collapse = ", "), call. = FALSE)
  if (!"npi_completeness" %in% names(ascertainment_raw))
    ascertainment_raw$npi_completeness <- NA_real_

  ascertainment <- ascertainment_raw |>
    dplyr::transmute(
      state = toupper(trimws(as.character(.data$state))),
      year = as.integer(.data$year),
      source = tolower(trimws(as.character(.data$source))),
      adequate_ascertainment = as.logical(.data$adequate_ascertainment),
      npi_completeness = as.numeric(.data$npi_completeness)
    ) |>
    dplyr::filter(.data$year == activity_year)
  # A missing flag must not silently license a zero.
  ascertainment$adequate_ascertainment <-
    !is.na(ascertainment$adequate_ascertainment) &
      ascertainment$adequate_ascertainment
  message("Usable ascertainment rows in ", activity_year, ": ",
          fmt_n(nrow(ascertainment)))

  activity_sources <- list()
  if (!is.null(taf_path)) {
    message("Reading normalized TAF delivery encounters.")
    activity_sources[["taf"]] <-
      read_delivery_activity(taf_path, "taf", activity_year)
    message("TAF delivery rows retained: ",
            fmt_n(nrow(activity_sources[["taf"]])))
  }
  if (!is.null(birth_cert_path)) {
    message("Reading normalized birth-certificate records.")
    activity_sources[["birth_certificate"]] <-
      read_delivery_activity(birth_cert_path, "birth_certificate",
                             activity_year)
    message("Birth-certificate delivery rows retained: ",
            fmt_n(nrow(activity_sources[["birth_certificate"]])))
  }

  observed_birth_events <- dplyr::bind_rows(activity_sources)
  message("Observed delivery records across sources: ",
          fmt_n(nrow(observed_birth_events)))

  message("Restricting observed activity to AMCB-active cohort.")
  cohort_birth_events <- observed_birth_events |>
    dplyr::semi_join(active_roster, by = "npi_activity")
  message("Observed delivery records linked to active cohort: ",
          fmt_n(nrow(cohort_birth_events)))

  message("Collapsing delivery events to NPI x year x source x location.")
  provider_location_activity <- cohort_birth_events |>
    dplyr::group_by(.data$npi_activity, .data$year, .data$source,
                    .data$state, .data$county_fips) |>
    dplyr::summarise(observed_births = sum(.data$birth_count, na.rm = TRUE),
                     .groups = "drop")
  message("Provider-location activity rows: ",
          fmt_n(nrow(provider_location_activity)))

  message("Collapsing activity across sources without double counting.")
  provider_source_activity <- provider_location_activity |>
    dplyr::group_by(.data$npi_activity, .data$year, .data$source) |>
    dplyr::summarise(births_source = sum(.data$observed_births, na.rm = TRUE),
                     .groups = "drop")

  # Sources OVERLAP: a Medicaid-financed birth appears in both TAF and the
  # birth certificate. Summing them would double count, so the per-provider
  # total is the MAXIMUM across sources -- a floor on true volume, never an
  # inflation of it.
  provider_activity_observed <- provider_source_activity |>
    dplyr::group_by(.data$npi_activity, .data$year) |>
    dplyr::summarise(
      taf_births = sum(.data$births_source[.data$source == "taf"],
                       na.rm = TRUE),
      birth_certificate_births =
        sum(.data$births_source[.data$source == "birth_certificate"],
            na.rm = TRUE),
      observed_any_birth = any(.data$births_source > 0),
      n_activity_sources =
        dplyr::n_distinct(.data$source[.data$births_source > 0]),
      .groups = "drop") |>
    dplyr::mutate(observed_births = pmax(.data$taf_births,
                                         .data$birth_certificate_births,
                                         na.rm = TRUE))

  message("Determining which midwives can legitimately be assigned zero births.")
  provider_states <- determine_provider_states(active_roster,
                                               cohort_birth_events)
  adequate_states <- ascertainment |>
    dplyr::filter(.data$adequate_ascertainment) |>
    dplyr::distinct(.data$state, .data$year) |>
    dplyr::mutate(ascertainment_adequate = TRUE)

  base_roster_year <- active_roster |>
    dplyr::mutate(year = as.integer(activity_year))

  provider_activity <- base_roster_year |>
    dplyr::left_join(provider_states, by = "npi_activity") |>
    dplyr::left_join(provider_activity_observed,
                     by = c("npi_activity", "year")) |>
    dplyr::left_join(adequate_states,
                     by = c("provider_state" = "state", "year")) |>
    dplyr::mutate(
      ascertainment_adequate =
        tidyr::replace_na(.data$ascertainment_adequate, FALSE),
      observed_any_birth = tidyr::replace_na(.data$observed_any_birth, FALSE),
      n_activity_sources = tidyr::replace_na(.data$n_activity_sources, 0L),
      taf_births = dplyr::if_else(.data$observed_any_birth,
                                  tidyr::replace_na(.data$taf_births, 0),
                                  NA_real_),
      birth_certificate_births =
        dplyr::if_else(.data$observed_any_birth,
                       tidyr::replace_na(.data$birth_certificate_births, 0),
                       NA_real_),
      # THE CORE RULE. A zero is emitted ONLY where ascertainment is declared
      # adequate. Everywhere else the value stays NA.
      observed_births = dplyr::case_when(
        .data$observed_any_birth ~ tidyr::replace_na(.data$observed_births, 0),
        .data$ascertainment_adequate ~ 0,
        TRUE ~ NA_real_),
      birth_activity_state = dplyr::case_when(
        .data$observed_any_birth ~ "observed_birth_attendant",
        .data$ascertainment_adequate ~ "no_observed_births",
        TRUE ~ "birth_activity_unobserved"),
      birth_active = dplyr::case_when(
        .data$birth_activity_state == "observed_birth_attendant" ~ TRUE,
        .data$birth_activity_state == "no_observed_births" ~ FALSE,
        TRUE ~ NA),
      birth_fte_weight = dplyr::case_when(
        is.na(.data$observed_births) ~ NA_real_,
        .data$observed_births <= 0 ~ 0,
        TRUE ~ pmin(.data$observed_births / reference_births, 1)))

  message("Assigning observed births to delivery counties.")
  location_weights <- provider_location_activity |>
    dplyr::group_by(.data$npi_activity, .data$year, .data$county_fips) |>
    dplyr::summarise(observed_births = max(.data$observed_births,
                                           na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::group_by(.data$npi_activity, .data$year) |>
    dplyr::mutate(
      provider_total_births = sum(.data$observed_births, na.rm = TRUE),
      birth_location_share = dplyr::if_else(
        .data$provider_total_births > 0,
        .data$observed_births / .data$provider_total_births,
        NA_real_)) |>
    dplyr::ungroup()

  message("Building county-level effective birth-attending supply.")
  county_base <- readr::read_csv(county_base_path, show_col_types = FALSE,
                                 progress = FALSE)
  if (!"GEOID" %in% names(county_base))
    stop("county_base_path must contain GEOID.", call. = FALSE)
  county_base <- county_base |>
    dplyr::mutate(GEOID = normalize_fips(.data$GEOID))

  county_observed_supply <- location_weights |>
    dplyr::left_join(
      provider_activity |>
        dplyr::select(dplyr::all_of(c("npi_activity", "year",
                                      "birth_fte_weight"))),
      by = c("npi_activity", "year")) |>
    dplyr::mutate(county_birth_fte = .data$birth_fte_weight *
                    .data$birth_location_share) |>
    dplyr::group_by(GEOID = .data$county_fips, .data$year) |>
    dplyr::summarise(
      observed_birth_attendants = dplyr::n_distinct(.data$npi_activity),
      observed_midwife_births = sum(.data$observed_births, na.rm = TRUE),
      effective_birth_fte = sum(.data$county_birth_fte, na.rm = TRUE),
      .groups = "drop")

  # A county with no OBSERVED attendant is given 0 here. That is a statement
  # about observation, not about supply: in a state whose ascertainment is not
  # established, zero means unobserved. Downstream maps must restrict to
  # adequately ascertained states before reading these as real zeros.
  county_effective_supply <- county_base |>
    dplyr::left_join(county_observed_supply, by = "GEOID") |>
    dplyr::mutate(
      observed_birth_attendants =
        tidyr::replace_na(.data$observed_birth_attendants, 0L),
      observed_midwife_births =
        tidyr::replace_na(.data$observed_midwife_births, 0),
      effective_birth_fte = tidyr::replace_na(.data$effective_birth_fte, 0))

  message("Testing whether observed birth activity differs by rurality.")
  validation_statistics <- validate_activity_by_rurality(provider_activity,
                                                         county_base)

  p <- function(stem) file.path(save_dir, sprintf("%s_%s_%s.csv", stem,
                                                  activity_year, timestamp))
  provider_path   <- p("midwife_birth_activity")
  location_path   <- p("midwife_birth_activity_location")
  county_path     <- p("county_effective_midwife_supply")
  validation_path <- p("birth_activity_rural_validation")

  # Every other numbered stage writes through write_with_provenance. This one
  # was added after that wiring went in and used readr::write_csv directly, so
  # its four artifacts were the only pipeline outputs a reader could not trace
  # back to the inputs that produced them. tests/ci_semantic_contracts.R now
  # asserts the invariant so the next stage cannot be added the same way.
  activity_inputs <- prov_inputs(roster_path, taf_path, birth_cert_path,
                                 ascertainment_path, county_base_path)

  message("Saving provider activity: ", provider_path)
  write_with_provenance(provider_activity, provider_path, inputs = activity_inputs)
  message("Saving provider-location activity: ", location_path)
  write_with_provenance(location_weights, location_path, inputs = activity_inputs)
  message("Saving county effective supply: ", county_path)
  write_with_provenance(county_effective_supply, county_path, inputs = activity_inputs)
  message("Saving rural validation: ", validation_path)
  write_with_provenance(validation_statistics, validation_path, inputs = activity_inputs)

  state_counts <- provider_activity |>
    dplyr::count(.data$birth_activity_state, name = "n")
  n_of <- function(s) sum(provider_activity$birth_activity_state == s)
  message("Observed birth attendants: ", fmt_n(n_of("observed_birth_attendant")))
  message("Ascertainable zero-birth midwives: ", fmt_n(n_of("no_observed_births")))
  message("Unobserved activity state: ", fmt_n(n_of("birth_activity_unobserved")))

  if (nrow(validation_statistics) > 0L) {
    v <- validation_statistics[1L, ]
    direction <- if (v$rural_zero_pct > v$urban_zero_pct) {
      "higher in rural counties"
    } else if (v$rural_zero_pct < v$urban_zero_pct) {
      "lower in rural counties"
    } else {
      "the same in rural and urban counties"
    }
    message(sprintf(paste0("In %d, the proportion of ascertainable AMCB-active ",
                           "midwives with zero observed births was %.1f%% in ",
                           "rural counties and %.1f%% in urban counties; the ",
                           "zero-birth proportion was %s (p=%s)."),
                    activity_year, v$rural_zero_pct, v$urban_zero_pct,
                    direction, format_p_value(v$p_value)))
  }

  message("build_midwife_birth_activity(): complete.")
  list(provider_activity = provider_activity,
       provider_location_activity = location_weights,
       county_effective_supply = county_effective_supply,
       validation_statistics = validation_statistics,
       activity_state_counts = state_counts,
       saved_paths = c(provider = provider_path, location = location_path,
                       county = county_path, validation = validation_path))
}

#' Read normalized delivery activity
#' @param path Input CSV. @param source_name Source label.
#' @param activity_year Analysis year.
#' @return [tbl_df] one row per delivery record or aggregate.
#' @keywords internal
read_delivery_activity <- function(path, source_name, activity_year) {
  message("read_delivery_activity(): source=", source_name, "; path=", path)
  delivery_records <- readr::read_csv(path, show_col_types = FALSE,
                                      progress = FALSE)
  required_columns <- c("npi", "year", "state", "county_fips")
  missing_columns <- setdiff(required_columns, names(delivery_records))
  if (length(missing_columns) > 0L)
    stop("Activity file is missing: ",
         paste(missing_columns, collapse = ", "), call. = FALSE)

  # birth_count is optional and defaults to one row = one birth. The column has
  # to be created BEFORE the data mask sees it: referencing .data$birth_count
  # inside if_else() errors when the column is absent, however the condition
  # evaluates.
  if (!"birth_count" %in% names(delivery_records))
    delivery_records$birth_count <- 1

  delivery_records |>
    dplyr::transmute(
      npi_activity = normalize_npi(.data$npi),
      year = as.integer(.data$year),
      state = toupper(trimws(as.character(.data$state))),
      county_fips = normalize_fips(.data$county_fips),
      birth_count = as.numeric(.data$birth_count),
      source = source_name) |>
    dplyr::filter(.data$year == activity_year,
                  !is.na(.data$npi_activity),
                  !is.na(.data$birth_count),
                  .data$birth_count > 0)
}

#' Determine best state for activity ascertainment
#' @param active_roster AMCB-active roster.
#' @param observed_birth_events Observed delivery events.
#' @return [tbl_df] one row per NPI with provider state.
#' @keywords internal
determine_provider_states <- function(active_roster, observed_birth_events) {
  state_col <- find_first_column(names(active_roster),
                                 c("state_best", "practice_state", "state",
                                   "address_state"))
  roster_states <- if (!is.na(state_col)) {
    tibble::tibble(npi_activity = active_roster$npi_activity,
                   roster_state = toupper(trimws(as.character(
                     active_roster[[state_col]]))))
  } else {
    tibble::tibble(npi_activity = active_roster$npi_activity,
                   roster_state = NA_character_)
  }

  if (nrow(observed_birth_events) == 0L) {
    return(roster_states |>
             dplyr::transmute(.data$npi_activity,
                              provider_state = .data$roster_state))
  }

  observed_states <- observed_birth_events |>
    dplyr::count(.data$npi_activity, .data$state, wt = .data$birth_count,
                 name = "births_in_state") |>
    dplyr::group_by(.data$npi_activity) |>
    dplyr::slice_max(order_by = .data$births_in_state, n = 1L,
                     with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::transmute(.data$npi_activity, observed_state = .data$state)

  roster_states |>
    dplyr::left_join(observed_states, by = "npi_activity") |>
    dplyr::mutate(provider_state = dplyr::coalesce(.data$observed_state,
                                                   .data$roster_state)) |>
    dplyr::select(dplyr::all_of(c("npi_activity", "provider_state")))
}

#' Validate inactive-certificant bias by rurality
#' @param provider_activity Provider-level activity table.
#' @param county_base County covariate table.
#' @return [tbl_df] one-row validation, or empty when not estimable.
#' @keywords internal
validate_activity_by_rurality <- function(provider_activity, county_base) {
  rural_col <- find_first_column(names(county_base),
                                 c("rucc_2023", "rucc", "RUCC_2023",
                                   "nchs_urban_rural"))
  if (is.na(rural_col)) {
    message("No rurality column found; skipping rural validation.")
    return(tibble::tibble())
  }

  # Only ASCERTAINABLE midwives can enter this comparison. Including the
  # unobserved ones would test data availability, not workforce activity.
  ascertainable <- provider_activity |>
    dplyr::filter(!is.na(.data$birth_active),
                  !is.na(.data$roster_county_fips)) |>
    dplyr::left_join(
      tibble::tibble(roster_county_fips = county_base$GEOID,
                     rural_code = suppressWarnings(
                       as.numeric(county_base[[rural_col]]))),
      by = "roster_county_fips") |>
    dplyr::filter(!is.na(.data$rural_code)) |>
    dplyr::mutate(rural = .data$rural_code >= 4,
                  zero_births = !.data$birth_active)

  if (nrow(ascertainable) == 0L ||
      dplyr::n_distinct(ascertainable$rural) < 2L) {
    message("Insufficient ascertainable rural/urban observations.")
    return(tibble::tibble())
  }

  # SEQUENTIAL EVALUATION SHADOWED THE SOURCE COLUMN. This was
  #   summarise(n = n(),
  #             zero_births = sum(zero_births),
  #             zero_pct = 100 * mean(zero_births))
  # where the third expression sees the NEWLY CREATED `zero_births` (a count)
  # rather than the original logical vector, so mean() was taken of a single
  # number and the percentage came out as 100 whenever any zero existed --
  # 1 of 2 rural midwives reported as 100%. It produced a plausible-looking
  # figure and always a null rural/urban difference, which is precisely the
  # comparison this validation exists to make. The output name is now distinct
  # from the input, and the percentage is derived arithmetically.
  rural_summary <- ascertainable |>
    dplyr::group_by(.data$rural) |>
    dplyr::summarise(n = dplyr::n(),
                     zero_n = sum(.data$zero_births),
                     .groups = "drop") |>
    dplyr::mutate(zero_pct = 100 * .data$zero_n / .data$n)

  contingency <- table(ascertainable$rural, ascertainable$zero_births)
  p_value <- if (all(dim(contingency) == 2L)) {
    stats::fisher.test(contingency)$p.value
  } else {
    NA_real_
  }

  rural_row <- rural_summary |> dplyr::filter(.data$rural)
  urban_row <- rural_summary |> dplyr::filter(!.data$rural)
  tibble::tibble(
    n_ascertainable = nrow(ascertainable),
    rural_n = rural_row$n, urban_n = urban_row$n,
    rural_zero_n = rural_row$zero_n,
    urban_zero_n = urban_row$zero_n,
    rural_zero_pct = rural_row$zero_pct,
    urban_zero_pct = urban_row$zero_pct,
    percentage_point_difference = rural_row$zero_pct - urban_row$zero_pct,
    p_value = p_value)
}

#' Find the first available column from a candidate list
#' @param available Available column names.
#' @param candidates Candidate names in priority order.
#' @return [character(1)] column name, or NA_character_ when none present.
#' @keywords internal
find_first_column <- function(available, candidates) {
  present <- candidates[candidates %in% available]
  if (length(present) > 0L) present[[1L]] else NA_character_
}

#' Normalize an NPI to ten digits
#' @param x NPI vector.
#' @return [character] ten-digit NPIs, NA otherwise.
#' @keywords internal
normalize_npi <- function(x) {
  normalized <- stringr::str_replace_all(as.character(x), "[^0-9]", "")
  normalized[nchar(normalized) != 10L] <- NA_character_
  normalized
}

#' Normalize a county FIPS to five characters
#' @param x County FIPS vector.
#' @return [character] zero-padded GEOIDs.
#' @keywords internal
normalize_fips <- function(x) {
  numeric_text <- stringr::str_replace_all(as.character(x), "[^0-9]", "")
  numeric_text[numeric_text == ""] <- NA_character_
  stringr::str_pad(numeric_text, width = 5L, side = "left", pad = "0")
}

#' Format a p value
#' @param x [numeric(1)]
#' @return [character(1)]
#' @keywords internal
format_p_value <- function(x) {
  if (length(x) != 1L || is.na(x)) return("NA")
  if (x < 0.001) return("<0.001")
  formatC(x, digits = 3L, format = "f")
}

#' Thousands-separated count, without depending on scales
#' @param x [numeric]
#' @return [character]
#' @keywords internal
fmt_n <- function(x) format(x, big.mark = ",", trim = TRUE)

#' Null-coalescing helper
#' @param x Value. @param y Replacement.
#' @return `x` unless NULL.
#' @keywords internal
`%||%` <- function(x, y) if (is.null(x)) y else x
