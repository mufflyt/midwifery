# =============================================================================
# helper-data-generation.R -- synthetic fixtures, ported from ~/isochrones
# =============================================================================
# PORTED from ~/isochrones/tests/testthat/helper-data-generation.R.
#
# WHY IT EARNS ITS PLACE HERE, when the other ports only added assertions: the
# artifacts carrying NPIs, names and certification dates are gitignored, so the
# tests that check them SKIP on a runner. Synthetic fixtures let those code
# paths execute in CI against data that resembles the real thing and describes
# nobody.
#
# DIVERGENCE, and a bug to send back upstream:
#
#   gen_npi() built an NPI as a random first digit plus NINE more random
#   digits, and called `valid_rate` of them valid. They are shape-valid only.
#   Of 200 generated with valid_rate = 0.9, exactly 15 carried a correct Luhn
#   check digit -- about one in ten, which is chance. Any fixture built from
#   them is rejected by contract_npi_valid(), and upstream any matcher test
#   asserting "these NPIs are valid" was asserting the wrong thing.
#
#   gen_npi() now computes the check digit instead of rolling a tenth die, via
#   npi_check_digit() below. `valid_rate` finally means what it says, and the
#   INVALID slots gained a seventh type: a well-shaped NPI with a deliberately
#   wrong check digit, which is the failure mode that motivated the fix and the
#   one the old generator could not produce on purpose.
#
# The isochrones-specific generators (specialties, retirement, isochrones) are
# kept verbatim rather than deleted, so this file can be diffed against its
# origin and the fix carried back.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
  library(stringr)
})

#' Generate realistic NPI values with controlled validity rate
#'
#' @param n Number of NPIs to generate
#' @param valid_rate Proportion that should be valid (0-1)
#' @param include_scientific Include scientific notation NPIs (Excel export
#'   issue)
#' @param include_short Include short/malformed NPIs
#' @param seed Random seed for reproducibility
#' @return Character vector of NPIs
#' Compute the Luhn check digit for the first nine digits of an NPI
#'
#' The payload is "80840" + those nine digits. Defined here rather than in
#' helper-invariants.R because that file VALIDATES and this one GENERATES, and
#' a generator that imports its own validator cannot catch a shared error.
#'
#' @param first9 [character(1)] nine digits.
#' @return [character(1)] the single check digit.
npi_check_digit <- function(first9) {
  d <- rev(as.integer(strsplit(paste0("80840", first9), "")[[1]]))
  i <- seq_along(d)
  dbl <- d
  dbl[i %% 2 == 1] <- d[i %% 2 == 1] * 2
  dbl <- ifelse(dbl > 9, dbl - 9, dbl)
  as.character((10 - (sum(dbl) %% 10)) %% 10)
}

#' A ten-digit NPI whose check digit is deliberately wrong
#'
#' @return [character(1)]
npi_wrong_check_digit <- function() {
  first9 <- paste0(c(sample(1:2, 1), sample(0:9, 8, replace = TRUE)), collapse = "")
  right <- as.integer(npi_check_digit(first9))
  paste0(first9, (right + sample(1:9, 1)) %% 10)
}

gen_npi <- function(n, valid_rate = 0.9, include_scientific = FALSE,
                   include_short = FALSE, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  npis <- character(n)

  # Generate genuinely valid NPIs: nine digits of payload plus the Luhn check
  # digit computed over "80840" + those nine. The original drew the tenth digit
  # at random, so ~90% of its "valid" NPIs were not.
  n_valid <- floor(n * valid_rate)
  if (n_valid > 0) {
    first9 <- replicate(n_valid, paste0(c(sample(1:2, 1), sample(0:9, 8, replace = TRUE)),
                                        collapse = ""))
    npis[1:n_valid] <- paste0(first9, vapply(first9, npi_check_digit, character(1),
                                             USE.NAMES = FALSE))
  }

  # Generate invalid NPIs for remaining slots
  if (n > n_valid) {
    remaining <- n - n_valid
    invalid_types <- if (include_scientific && include_short) {
      sample(1:6, remaining, replace = TRUE)
    } else if (include_scientific) {
      sample(c(1, 2, 5, 6), remaining, replace = TRUE)
    } else if (include_short) {
      sample(c(1, 3, 4, 5, 6), remaining, replace = TRUE)
    } else {
      sample(c(1, 5, 6, 7), remaining, replace = TRUE)
    }

    for (i in (n_valid + 1):n) {
      type <- invalid_types[i - n_valid]
      npis[i] <- switch(type,
        "1" = "12345678901",     # Too long (11 digits)
        "2" = "1.23e+09",        # Scientific notation
        "3" = "123",             # Too short
        "4" = "123456789",       # 9 digits (missing leading zero)
        "5" = "abc123def0",      # Contains letters
        "6" = "",                # Empty string
        # ADDED: right shape, wrong check digit. The old generator could not
        # produce this deliberately, which is exactly the case a validator that
        # checks only width and digits waves through.
        "7" = npi_wrong_check_digit()
      )
    }
  }

  # Shuffle to randomize order
  sample(npis)
}

#' Generate realistic gender values with controlled validity rate
#'
#' @param n Number of gender values to generate
#' @param valid_rate Proportion that should be valid (0-1)
#' @param include_numeric Include numeric codes (1/2)
#' @param seed Random seed for reproducibility
#' @return Character vector of gender values
gen_gender <- function(n, valid_rate = 0.9, include_numeric = TRUE, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  genders <- character(n)

  # Valid gender formats (will canonicalize to Male/Female)
  valid_genders <- if (include_numeric) {
    c("Male", "Female", "M", "F", "1", "2", "MALE", "FEMALE", "m", "f")
  } else {
    c("Male", "Female", "M", "F", "MALE", "FEMALE", "m", "f")
  }

  # Generate mostly valid genders
  n_valid <- floor(n * valid_rate)
  if (n_valid > 0) {
    genders[1:n_valid] <- sample(valid_genders, n_valid, replace = TRUE)
  }

  # Generate invalid genders for remaining slots
  if (n > n_valid) {
    remaining <- n - n_valid
    invalid_genders <- c("X", "Unknown", "Other", "U", "3", "0", "", NA_character_)
    genders[(n_valid + 1):n] <- sample(invalid_genders, remaining, replace = TRUE)
  }

  # Shuffle to randomize order
  sample(genders)
}

#' Generate realistic state codes with controlled validity rate
#'
#' @param n Number of state codes to generate
#' @param valid_rate Proportion that should be valid (0-1)
#' @param include_territories Include US territories (PR, VI, etc.)
#' @param include_lowercase Include lowercase variants
#' @param seed Random seed for reproducibility
#' @return Character vector of state codes
gen_state <- function(n, valid_rate = 0.9, include_territories = TRUE,
                     include_lowercase = TRUE, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  states <- character(n)

  # Valid state codes
  valid_states <- if (include_territories) {
    c(state.abb, "DC", "PR", "VI", "GU", "AS", "MP")
  } else {
    c(state.abb, "DC")
  }

  if (include_lowercase) {
    valid_states <- c(valid_states, tolower(valid_states))
  }

  # Generate mostly valid states
  n_valid <- floor(n * valid_rate)
  if (n_valid > 0) {
    states[1:n_valid] <- sample(valid_states, n_valid, replace = TRUE)
  }

  # Generate invalid states for remaining slots
  if (n > n_valid) {
    remaining <- n - n_valid
    invalid_states <- c("XX", "ZZ", "ABC", "12", "QQ", "", NA_character_, "USA", "US")
    states[(n_valid + 1):n] <- sample(invalid_states, remaining, replace = TRUE)
  }

  # Shuffle to randomize order
  sample(states)
}

#' Generate realistic year values with controlled validity rate
#'
#' @param n Number of year values to generate
#' @param valid_rate Proportion that should be valid (0-1)
#' @param year_range Range of valid years (default 1950-2025)
#' @param include_strings Include string representations
#' @param seed Random seed for reproducibility
#' @return Numeric or character vector of years
gen_year <- function(n, valid_rate = 0.9, year_range = c(1950, 2025),
                    include_strings = TRUE, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  years <- character(n)  # Start as character for flexibility

  # Generate mostly valid years
  n_valid <- floor(n * valid_rate)
  if (n_valid > 0) {
    valid_years <- sample(year_range[1]:year_range[2], n_valid, replace = TRUE)
    years[1:n_valid] <- if (include_strings) {
      ifelse(runif(n_valid) < 0.5, as.character(valid_years), valid_years)
    } else {
      as.character(valid_years)
    }
  }

  # Generate invalid years for remaining slots
  if (n > n_valid) {
    remaining <- n - n_valid
    invalid_years <- c("abc", "2025a", "1800", "3000", "", NA_character_, "0", "-1")
    years[(n_valid + 1):n] <- sample(invalid_years, remaining, replace = TRUE)
  }

  # Shuffle to randomize order
  sample(years)
}

#' Generate realistic physician names
#'
#' @param n Number of names to generate
#' @param include_suffixes Include MD, Jr, Sr, etc.
#' @param include_middle Include middle names/initials
#' @param seed Random seed for reproducibility
#' @return Tibble with first_name, last_name, full_name columns
gen_names <- function(n, include_suffixes = TRUE, include_middle = TRUE, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  # Common first names for physicians
  first_names <- c(
    "James", "Mary", "John", "Patricia", "Robert", "Jennifer", "Michael", "Linda",
    "William", "Elizabeth", "David", "Barbara", "Richard", "Susan", "Joseph", "Jessica",
    "Thomas", "Sarah", "Christopher", "Karen", "Daniel", "Nancy", "Matthew", "Lisa",
    "Anthony", "Betty", "Mark", "Helen", "Donald", "Sandra", "Steven", "Donna"
  )

  # Common last names for physicians
  last_names <- c(
    "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis",
    "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson", "Thomas",
    "Taylor", "Moore", "Jackson", "Martin", "Lee", "Perez", "Thompson", "White",
    "Harris", "Sanchez", "Clark", "Ramirez", "Lewis", "Robinson", "Walker", "Young"
  )

  # Suffixes common in medical field
  suffixes <- c("MD", "Jr", "Sr", "III", "II", "DO", "MD PhD")
  middle_initials <- LETTERS[1:26]

  result <- tibble(
    first_name = sample(first_names, n, replace = TRUE),
    last_name = sample(last_names, n, replace = TRUE)
  )

  # Add middle names/initials if requested
  if (include_middle) {
    result$middle <- ifelse(
      runif(n) < 0.6,  # 60% have middle initial
      sample(middle_initials, n, replace = TRUE),
      ""
    )
  }

  # Add suffixes if requested
  if (include_suffixes) {
    result$suffix <- ifelse(
      runif(n) < 0.8,  # 80% have MD or other suffix
      sample(suffixes, n, replace = TRUE),
      ""
    )
  }

  # Create full name
  result$full_name <- paste(
    result$first_name,
    if (include_middle) result$middle else "",
    result$last_name,
    if (include_suffixes) result$suffix else ""
  ) %>%
    str_replace_all("\\s+", " ") %>%  # Normalize whitespace
    str_trim()

  result
}

#' Generate realistic specialty codes and names
#'
#' @param n Number of specialties to generate
#' @param subspecialty_rate Proportion that should be subspecialties
#' @param seed Random seed for reproducibility
#' @return Tibble with specialty_code, specialty_name, is_subspecialty columns
gen_specialties <- function(n, subspecialty_rate = 0.3, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  # Primary specialties
  primary_specialties <- c(
    "Internal Medicine", "Family Medicine", "Pediatrics", "OB/GYN", "Surgery",
    "Cardiology", "Dermatology", "Neurology", "Psychiatry", "Radiology",
    "Anesthesiology", "Emergency Medicine", "Pathology", "Ophthalmology", "Urology"
  )

  # Subspecialties (more specific)
  subspecialties <- c(
    "Gynecologic Oncology", "Maternal-Fetal Medicine", "Reproductive Endocrinology",
    "Urogynecology", "Cardiothoracic Surgery", "Plastic Surgery", "Orthopedic Surgery",
    "Neurosurgery", "Vascular Surgery", "Interventional Cardiology", "Electrophysiology",
    "Pediatric Cardiology", "Neonatal-Perinatal Medicine", "Pediatric Surgery"
  )

  n_subspecialty <- floor(n * subspecialty_rate)
  n_primary <- n - n_subspecialty

  # Generate primary specialties
  primary_sample <- if (n_primary > 0) {
    sample(primary_specialties, n_primary, replace = TRUE)
  } else {
    character(0)
  }

  # Generate subspecialties
  subspecialty_sample <- if (n_subspecialty > 0) {
    sample(subspecialties, n_subspecialty, replace = TRUE)
  } else {
    character(0)
  }

  # Combine and create result
  all_specialties <- c(primary_sample, subspecialty_sample)
  all_subspecialty_flags <- c(rep(FALSE, n_primary), rep(TRUE, n_subspecialty))

  # Shuffle
  indices <- sample(n)
  all_specialties <- all_specialties[indices]
  all_subspecialty_flags <- all_subspecialty_flags[indices]

  tibble(
    specialty_code = paste0("SPEC_", str_pad(1:n, width = 3, pad = "0")),
    specialty_name = all_specialties,
    is_subspecialty = all_subspecialty_flags
  )
}

#' Create realistic test dataset for physician data
#'
#' @param n Number of physicians to generate
#' @param coverage_rate What proportion should have complete data
#' @param duplicate_rate What proportion should have duplicate NPIs
#' @param seed Random seed for reproducibility
#' @return Tibble with realistic physician data
create_test_physicians <- function(n, coverage_rate = 0.9, duplicate_rate = 0.05, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  # Generate names
  names_data <- gen_names(n, seed = seed)

  # Create base dataset
  physicians <- tibble(
    npi = gen_npi(n, valid_rate = coverage_rate, seed = seed + 1),
    first_name = names_data$first_name,
    last_name = names_data$last_name,
    full_name = names_data$full_name,
    gender = gen_gender(n, valid_rate = coverage_rate, seed = seed + 2),
    state = gen_state(n, valid_rate = coverage_rate, seed = seed + 3),
    graduation_year = as.numeric(gen_year(n, valid_rate = coverage_rate,
                                         year_range = c(1970, 2023), seed = seed + 4)),
    age = pmax(25, 2024 - as.numeric(gen_year(n, valid_rate = coverage_rate,
                                             year_range = c(1950, 1999), seed = seed + 5)))
  )

  # Introduce some duplicates if requested
  if (duplicate_rate > 0) {
    n_duplicates <- floor(n * duplicate_rate)
    if (n_duplicates > 0) {
      # Pick some NPIs to duplicate
      duplicate_indices <- sample(which(!is.na(physicians$npi)), n_duplicates)
      original_npis <- physicians$npi[duplicate_indices]

      # Create duplicate rows
      duplicate_rows <- physicians[duplicate_indices, ] %>%
        mutate(
          # Slightly modify other fields for realism
          first_name = paste0(first_name, "_DUP"),
          state = sample(state, n())
        )

      # Add duplicates to main dataset
      physicians <- bind_rows(physicians, duplicate_rows)
    }
  }

  physicians
}

#' Create realistic test dataset for specialty/NPI matching
#'
#' @param physician_npis Vector of NPIs to create specialties for
#' @param coverage_rate What proportion of NPIs should have specialty matches
#' @param duplicate_rate What proportion should have multiple specialties
#' @param seed Random seed for reproducibility
#' @return Tibble with NPI-specialty mappings
create_test_specialties <- function(physician_npis, coverage_rate = 0.8,
                                   duplicate_rate = 0.1, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  # Filter to valid NPIs only
  valid_npis <- physician_npis[!is.na(physician_npis) & physician_npis != ""]
  n_valid <- length(valid_npis)

  if (n_valid == 0) {
    return(tibble(npi = character(0), specialty_code = character(0),
                  specialty_name = character(0), is_primary = logical(0)))
  }

  # Determine how many NPIs get specialty matches
  n_with_specialty <- floor(n_valid * coverage_rate)
  npis_with_specialty <- sample(valid_npis, n_with_specialty)

  # Generate specialty data
  specialty_data <- gen_specialties(n_with_specialty, seed = seed)

  # Create base specialty assignments
  base_specialties <- tibble(
    npi = npis_with_specialty,
    specialty_code = specialty_data$specialty_code,
    specialty_name = specialty_data$specialty_name,
    is_primary = TRUE
  )

  # Add some NPIs with multiple specialties if requested
  if (duplicate_rate > 0) {
    n_multiple <- floor(n_with_specialty * duplicate_rate)
    if (n_multiple > 0) {
      # Pick NPIs to have secondary specialties
      multi_npis <- sample(npis_with_specialty, n_multiple)

      # Generate secondary specialties
      secondary_specialty_data <- gen_specialties(n_multiple, seed = seed + 100)

      secondary_specialties <- tibble(
        npi = multi_npis,
        specialty_code = secondary_specialty_data$specialty_code,
        specialty_name = secondary_specialty_data$specialty_name,
        is_primary = FALSE
      )

      # Combine
      base_specialties <- bind_rows(base_specialties, secondary_specialties)
    }
  }

  base_specialties %>%
    arrange(npi, desc(is_primary))  # Primary specialties first
}

#' Generate realistic US addresses for geocoding tests
#'
#' @param n Number of addresses to generate
#' @param include_coordinates Include lat/lon coordinates
#' @param valid_rate Proportion that should be valid addresses
#' @param seed Random seed for reproducibility
#' @return Tibble with address components and optional coordinates
gen_addresses <- function(n, include_coordinates = TRUE, valid_rate = 0.9, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  # Street names
  street_names <- c(
    "Main", "First", "Second", "Third", "Elm", "Oak", "Maple", "Park", "Washington",
    "Broadway", "Market", "Spring", "Center", "Church", "Pine", "Walnut", "Hill",
    "Cedar", "Adams", "Madison", "Jefferson", "Lincoln", "Franklin", "Jackson"
  )

  street_types <- c("St", "Ave", "Rd", "Blvd", "Dr", "Ln", "Way", "Pl", "Ct")

  # Common cities by state (selected states)
  city_state_map <- list(
    CA = c("Los Angeles", "San Francisco", "San Diego", "Sacramento", "Oakland"),
    NY = c("New York", "Buffalo", "Rochester", "Albany", "Syracuse"),
    TX = c("Houston", "Dallas", "Austin", "San Antonio", "Fort Worth"),
    FL = c("Miami", "Tampa", "Orlando", "Jacksonville", "St Petersburg"),
    IL = c("Chicago", "Aurora", "Naperville", "Joliet", "Rockford"),
    PA = c("Philadelphia", "Pittsburgh", "Allentown", "Erie", "Reading"),
    OH = c("Columbus", "Cleveland", "Cincinnati", "Toledo", "Akron"),
    GA = c("Atlanta", "Augusta", "Columbus", "Savannah", "Athens"),
    NC = c("Charlotte", "Raleigh", "Greensboro", "Durham", "Winston-Salem"),
    MI = c("Detroit", "Grand Rapids", "Warren", "Sterling Heights", "Lansing")
  )

  n_valid <- floor(n * valid_rate)

  # Generate valid addresses
  valid_states <- names(city_state_map)
  address_states <- sample(valid_states, n_valid, replace = TRUE)

  addresses <- tibble(
    street_number = sample(100:9999, n, replace = TRUE),
    street_name = sample(street_names, n, replace = TRUE),
    street_type = sample(street_types, n, replace = TRUE),
    city = character(n),
    state = character(n),
    zip_code = character(n)
  )

  # Fill valid addresses
  for (i in 1:n_valid) {
    state <- address_states[i]
    addresses$city[i] <- sample(city_state_map[[state]], 1)
    addresses$state[i] <- state
    # Generate realistic ZIP codes (first 2 digits based on state)
    zip_prefix <- switch(state,
      CA = sample(90:96, 1),
      NY = sample(10:14, 1),
      TX = sample(75:79, 1),
      FL = sample(32:34, 1),
      IL = sample(60:62, 1),
      PA = sample(15:19, 1),
      OH = sample(43:45, 1),
      GA = sample(30:31, 1),
      NC = sample(27:28, 1),
      MI = sample(48:49, 1),
      sample(10:99, 1)
    )
    addresses$zip_code[i] <- paste0(zip_prefix, sample(100:999, 1))
  }

  # Fill invalid addresses
  if (n > n_valid) {
    invalid_cities <- c("", NA_character_, "Unknown", "123", "City")
    invalid_states <- c("", NA_character_, "XX", "ZZ", "ABC")
    invalid_zips <- c("", NA_character_, "123", "ABCDE", "00000")

    for (i in (n_valid + 1):n) {
      addresses$city[i] <- sample(invalid_cities, 1)
      addresses$state[i] <- sample(invalid_states, 1)
      addresses$zip_code[i] <- sample(invalid_zips, 1)
    }
  }

  # Create full address string
  addresses$full_address <- paste(
    addresses$street_number,
    addresses$street_name,
    addresses$street_type,
    paste0(addresses$city, ","),
    addresses$state,
    addresses$zip_code
  ) %>%
    str_replace_all("\\s+", " ") %>%
    str_trim()

  # Add coordinates if requested
  if (include_coordinates) {
    # Valid coordinates (continental US bounds)
    lat_bounds <- c(25, 49)  # Roughly FL to Canada
    lon_bounds <- c(-125, -67)  # Pacific to Atlantic

    addresses$latitude <- ifelse(
      1:n <= n_valid,
      runif(n, lat_bounds[1], lat_bounds[2]),
      NA_real_
    )
    addresses$longitude <- ifelse(
      1:n <= n_valid,
      runif(n, lon_bounds[1], lon_bounds[2]),
      NA_real_
    )
  }

  addresses
}

#' Generate retirement detection test data
#'
#' @param physician_npis Vector of NPIs to create retirement data for
#' @param retirement_rate Proportion that should be retired
#' @param include_year_estimates Include estimated retirement years
#' @param seed Random seed for reproducibility
#' @return Tibble with retirement flags and years
create_test_retirement <- function(physician_npis, retirement_rate = 0.15,
                                  include_year_estimates = TRUE, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  # Filter to valid NPIs
  valid_npis <- physician_npis[!is.na(physician_npis) & physician_npis != ""]
  n <- length(valid_npis)

  if (n == 0) {
    return(tibble(
      npi = character(0),
      retired_flag = logical(0),
      retirement_year = integer(0),
      retirement_confidence = numeric(0),
      retirement_source = character(0)
    ))
  }

  # Generate retirement flags
  n_retired <- floor(n * retirement_rate)
  retired_indices <- sample(n, n_retired)

  retirement_data <- tibble(
    npi = valid_npis,
    retired_flag = 1:n %in% retired_indices
  )

  # Add retirement years if requested
  if (include_year_estimates) {
    retirement_data$retirement_year <- ifelse(
      retirement_data$retired_flag,
      sample(2015:2024, n, replace = TRUE),
      NA_integer_
    )

    # Add confidence scores
    retirement_data$retirement_confidence <- ifelse(
      retirement_data$retired_flag,
      runif(n, 0.70, 0.99),
      NA_real_
    )

    # Add sources
    sources <- c("NPPES_deactivation", "Medicare_cessation", "State_license",
                 "ABMS_certification", "Hospital_affiliation")
    retirement_data$retirement_source <- ifelse(
      retirement_data$retired_flag,
      sample(sources, n, replace = TRUE),
      NA_character_
    )
  }

  retirement_data
}

#' Generate isochrone polygon test data
#'
#' @param coordinates Tibble with latitude/longitude columns
#' @param travel_times Vector of travel time thresholds (minutes)
#' @param seed Random seed for reproducibility
#' @return sf object with POLYGON geometries for each coordinate and travel time
create_test_isochrones <- function(coordinates, travel_times = c(30, 60, 120, 180), seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' required for isochrone generation. Install with: install.packages('sf')")
  }

  library(sf)

  # Filter to valid coordinates
  valid_coords <- coordinates %>%
    filter(!is.na(latitude) & !is.na(longitude))

  if (nrow(valid_coords) == 0) {
    return(st_sf(
      travel_time = integer(0),
      geometry = st_sfc(crs = 4326)
    ))
  }

  # Create isochrones for each coordinate and travel time
  isochrones <- list()
  idx <- 1

  for (i in seq_len(nrow(valid_coords))) {
    lat <- valid_coords$latitude[i]
    lon <- valid_coords$longitude[i]

    for (travel_time in travel_times) {
      # Approximate radius in degrees (very rough: 1 degree ≈ 69 miles)
      # 60 mph average speed, so 30 min = 30 miles ≈ 0.43 degrees
      radius_degrees <- (travel_time / 60) * 60 / 69

      # Add some random variation
      radius_degrees <- radius_degrees * runif(1, 0.8, 1.2)

      # Create a simple circular polygon (oversimplified, but good for testing)
      n_points <- 32
      angles <- seq(0, 2 * pi, length.out = n_points + 1)[-1]

      polygon_coords <- data.frame(
        lon = lon + radius_degrees * cos(angles),
        lat = lat + radius_degrees * sin(angles)
      )

      # Close the polygon
      polygon_coords <- rbind(polygon_coords, polygon_coords[1, ])

      # Create sf polygon
      poly <- st_polygon(list(as.matrix(polygon_coords)))

      isochrones[[idx]] <- list(
        provider_id = if ("provider_id" %in% names(valid_coords)) {
          valid_coords$provider_id[i]
        } else {
          paste0("PROV_", str_pad(i, 4, pad = "0"))
        },
        travel_time = travel_time,
        geometry = poly
      )
      idx <- idx + 1
    }
  }

  # Convert to sf object
  result <- st_sf(
    provider_id = sapply(isochrones, function(x) x$provider_id),
    travel_time = sapply(isochrones, function(x) x$travel_time),
    geometry = st_sfc(lapply(isochrones, function(x) x$geometry), crs = 4326)
  )

  result
}

# (informational cat() calls removed — they polluted test output on every source)
# =============================================================================
# midwifery-specific fixtures (added here, not present upstream)
# =============================================================================

#' Build a synthetic AMCB-to-NPI linkage
#'
#' Shaped like artifacts/amcb_npi_linkage_FROZEN_*.csv -- certification number,
#' name, MM/YYYY dates, and an NPI for the linked share -- so the contracts that
#' skip in CI for want of the real (gitignored) artifact can run against
#' something that describes nobody.
#'
#' @param n [integer(1)] rows.
#' @param linked_rate [numeric(1)] share carrying an NPI; the rest are
#'   unmatched, which is the real artifact's shape (65.7% primary linkage).
#' @param seed [integer(1)|NULL]
#' @param corrupt [character(1)] plant a defect: "none", "duplicate_npi",
#'   "invalid_npi", "reversed_dates", "blank_zip".
#' @return [data.frame]
create_test_amcb_linkage <- function(n = 200, linked_rate = 0.657, seed = NULL,
                                     corrupt = c("none", "duplicate_npi", "invalid_npi",
                                                 "reversed_dates", "blank_zip")) {
  corrupt <- match.arg(corrupt)
  if (!is.null(seed)) set.seed(seed)

  n_linked <- floor(n * linked_rate)
  npi <- c(gen_npi(n_linked, valid_rate = 1), rep(NA_character_, n - n_linked))

  cert_year <- sample(1980:2024, n, replace = TRUE)
  cert_month <- sprintf("%02d", sample(1:12, n, replace = TRUE))
  exp_year <- cert_year + sample(5:40, n, replace = TRUE)

  d <- data.frame(
    certification_number = sprintf("%06d", seq_len(n)),
    last_name  = paste0("SURNAME", seq_len(n)),
    first_name = paste0("GIVEN", seq_len(n)),
    npi = npi,
    certification_date = paste0(cert_month, "/", cert_year),
    expiration_date    = paste0("12/", exp_year),
    practice_zip = sprintf("%05d", sample(1000:99999, n, replace = TRUE)),
    stringsAsFactors = FALSE
  )

  # Planted defects, so a test can prove the guard fires rather than only that
  # clean data passes. A guard never seen to fail is not known to work.
  switch(corrupt,
    duplicate_npi  = { d$npi[2] <- d$npi[1] },
    invalid_npi    = { d$npi[1] <- npi_wrong_check_digit() },
    reversed_dates = { d$expiration_date[1] <- "01/1900" },
    blank_zip      = { d$practice_zip[1:3] <- c("", "  ", "NA") },
    none = NULL)
  d
}
