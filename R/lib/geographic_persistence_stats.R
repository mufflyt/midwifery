#' Geographic persistence statistics from a resolved provider-year table
#'
#' Shared core for every county-resolution method
#' `docs/RESULTS_geographic_persistence.md` compares (ZCTA-crosswalk,
#' canonical 3-tier-cascade geocode, and any future one): annual and career
#' persistence, RUCC-origin rurality stratification, and the movers table.
#' Factored out of `build_results_geographic_persistence.R` so a second
#' method's script cannot become a private, drifting copy of this logic --
#' only the COUNTY SOURCE differs between methods; what happens with a county
#' once resolved does not.
#'
#' @param py [data.frame] one row per provider-year, already resolved by the
#'   caller's own method. Required columns: `npi`, `snapshot_year`,
#'   `practice_zip`, `practice_state`, `county_fips` (NA where unresolved),
#'   `rucc_cat` (NA where `county_fips` is NA or maps to no RUCC row).
#' @return [list] `panel` (observed/provider_years/median_years/pairs_total/
#'   pairs_used/providers_used/median_span), `rates` (annual + career, same
#'   county/ZIP/state), `rurality` (origin-stratified annual + career same
#'   county), `movers` (origin x destination career-mover counts, zero-filled).
#' @family geographic-persistence
compute_geographic_persistence_stats <- function(py) {
  stopifnot(all(c("npi", "snapshot_year", "practice_zip", "practice_state",
                  "county_fips", "rucc_cat") %in% names(py)))

  providers_observed <- dplyr::n_distinct(py$npi)
  provider_years <- nrow(py)
  years_per_provider <- py %>% dplyr::count(npi, name = "n_years")
  panel <- list(
    snapshots = dplyr::n_distinct(py$snapshot_year),
    year_min = min(py$snapshot_year), year_max = max(py$snapshot_year),
    observed = providers_observed, provider_years = provider_years,
    median_years = median(years_per_provider$n_years)
  )

  # Consecutive OBSERVED snapshot years per provider, not necessarily y/y+1 --
  # a provider can have a gap year.
  pairs <- py %>%
    dplyr::arrange(npi, snapshot_year) %>%
    dplyr::group_by(npi) %>%
    dplyr::mutate(prev_year = dplyr::lag(snapshot_year), prev_county = dplyr::lag(county_fips),
                  prev_zip = dplyr::lag(practice_zip), prev_state = dplyr::lag(practice_state)) %>%
    dplyr::ungroup() %>%
    dplyr::filter(!is.na(prev_year)) %>%
    dplyr::transmute(npi, year_from = prev_year, year_to = snapshot_year,
                     same_county = !is.na(county_fips) & !is.na(prev_county) & county_fips == prev_county,
                     same_zip = !is.na(practice_zip) & !is.na(prev_zip) & practice_zip == prev_zip,
                     same_state = !is.na(practice_state) & !is.na(prev_state) & practice_state == prev_state,
                     county_resolved = !is.na(county_fips) & !is.na(prev_county))

  annual <- pairs %>% dplyr::summarise(
    pairs_total = dplyr::n(), pairs_used = sum(county_resolved),
    annual_county = 100 * sum(same_county[county_resolved]) / sum(county_resolved),
    annual_zip = 100 * mean(same_zip), annual_state = 100 * mean(same_state))

  career_pairs <- py %>%
    dplyr::arrange(npi, snapshot_year) %>%
    dplyr::group_by(npi) %>%
    dplyr::filter(dplyr::n() > 1) %>%
    dplyr::summarise(
      first_county = dplyr::first(county_fips), last_county = dplyr::last(county_fips),
      first_zip = dplyr::first(practice_zip), last_zip = dplyr::last(practice_zip),
      first_state = dplyr::first(practice_state), last_state = dplyr::last(practice_state),
      first_year = dplyr::first(snapshot_year), last_year = dplyr::last(snapshot_year),
      first_rucc = dplyr::first(rucc_cat),
      .groups = "drop") %>%
    dplyr::mutate(county_resolved = !is.na(first_county) & !is.na(last_county),
                  same_county = county_resolved & first_county == last_county,
                  same_zip = !is.na(first_zip) & !is.na(last_zip) & first_zip == last_zip,
                  same_state = !is.na(first_state) & !is.na(last_state) & first_state == last_state,
                  span = last_year - first_year)

  career <- career_pairs %>% dplyr::summarise(
    providers_used = dplyr::n(), median_span = median(span),
    career_county = 100 * sum(same_county[county_resolved]) / sum(county_resolved),
    career_zip = 100 * mean(same_zip), career_state = 100 * mean(same_state))

  rates <- dplyr::bind_rows(
    tibble::tibble(horizon = "year_to_year", n = annual$pairs_used,
                   same_county_pct = annual$annual_county, same_zip_pct = annual$annual_zip,
                   same_state_pct = annual$annual_state),
    tibble::tibble(horizon = "first_vs_last", n = career$providers_used,
                   same_county_pct = career$career_county, same_zip_pct = career$career_zip,
                   same_state_pct = career$career_state)
  )

  origin_annual <- pairs %>%
    dplyr::left_join(career_pairs %>% dplyr::select(npi, first_rucc), by = "npi") %>%
    dplyr::filter(!is.na(first_rucc)) %>%
    dplyr::group_by(origin = first_rucc) %>%
    dplyr::summarise(providers = dplyr::n_distinct(npi),
                     annual_same_county = 100 * sum(same_county[county_resolved]) / sum(county_resolved),
                     .groups = "drop")

  origin_career <- career_pairs %>%
    dplyr::filter(!is.na(first_rucc), county_resolved) %>%
    dplyr::group_by(origin = first_rucc) %>%
    dplyr::summarise(providers = dplyr::n(),
                     career_same_county = 100 * sum(same_county) / dplyr::n(),
                     .groups = "drop")

  rurality <- origin_annual %>%
    dplyr::select(origin, providers, annual_same_county) %>%
    dplyr::left_join(origin_career %>% dplyr::select(origin, career_same_county), by = "origin") %>%
    dplyr::mutate(origin = factor(origin, levels = RURALITY_LABELS_SHORT)) %>%
    dplyr::arrange(origin)

  # county_fips -> rucc_cat for the DESTINATION side of a move. py already
  # carries rucc_cat per provider-year, so build the lookup from py itself
  # rather than re-deriving it, keeping this function agnostic to which
  # county-resolution method the caller used.
  dest_rucc <- py %>% dplyr::distinct(county_fips, rucc_cat) %>%
    dplyr::filter(!is.na(county_fips))

  movers <- career_pairs %>%
    dplyr::filter(county_resolved, !same_county, !is.na(first_rucc)) %>%
    dplyr::left_join(dest_rucc, by = c("last_county" = "county_fips")) %>%
    dplyr::rename(destination = rucc_cat) %>%
    dplyr::filter(!is.na(destination)) %>%
    dplyr::count(origin = first_rucc, destination) %>%
    dplyr::mutate(origin = factor(origin, levels = RURALITY_LABELS_SHORT),
                  destination = factor(destination, levels = RURALITY_LABELS_SHORT)) %>%
    tidyr::complete(origin, destination, fill = list(n = 0)) %>%
    dplyr::arrange(origin, destination)

  panel$pairs_total <- annual$pairs_total
  panel$pairs_used <- annual$pairs_used
  panel$providers_used <- career$providers_used
  panel$median_span <- career$median_span

  list(panel = panel, rates = rates, rurality = rurality, movers = movers)
}
