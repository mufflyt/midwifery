#!/usr/bin/env Rscript

#' @title Safe Division with Zero-Denominator Handling
#' @description Performs division with explicit handling of zero denominators
#'   to prevent Inf/NaN propagation and silent failures. Supports multiple
#'   legacy parameter signatures for project-wide compatibility.
#'
#' @section Safe Division Family:
#' This file defines six related functions that all share the same guarantee:
#' a zero or NA denominator never produces \code{Inf}, \code{NaN}, or an
#' uncaught error — it returns a caller-specified default instead.  Choose the
#' variant that matches the calling context:
#'
#' \describe{
#'   \item{\code{safe_divide()}}{The core primitive used inside pipeline
#'     computations.  Returns \code{NA_real_} by default on a zero denominator
#'     so that downstream logic can detect and handle missing values
#' explicitly.}
#'   \item{\code{safe_divide_manu()}}{A thin alias of \code{safe_divide()} with
#'     parameter names (\code{num}/\code{den}/\code{fallback}) that match the
#'     naming conventions used throughout \code{manuscript/R/}.  Use this
#'     whenever you are converting raw counts to millions-scale values inside a
#'     manuscript script.}
#'   \item{\code{safe_pct_manu()}}{Returns a rounded percentage value (e.g.,
#'     \code{45.0}) rather than a proportion, with \code{0} on a zero
#'     denominator.  Use this for inline manuscript statistics where
#'     \code{"0\%"} is a more informative display value than \code{NA}.}
#'   \item{\code{safe_percent()}}{The standard percentage function for all
#'     pipeline metrics and figure annotations.  Computes
#'     \code{round((part / total) * 100, digits)} and returns \code{default}
#'     (0 by default) when \code{total} is zero.}
#'   \item{\code{safe_rate()}}{Used for epidemiological rates such as
#'     subspecialists per 100K women.  Multiplies the safe quotient by a
#'     \code{multiplier} argument before rounding, and returns \code{NA_real_}
#'     on a zero denominator so that sparse census tracts are distinguishable
#'     from truly zero-rate tracts.}
#'   \item{\code{safe_ratio()}}{Produces a rounded unitless ratio (e.g.,
#'     MOE-to-estimate, physician-to-population).  Returns \code{NA_real_} on a
#'     zero denominator.  Differs from \code{safe_percent()} in that it does
#'     not multiply by 100, and from \code{safe_rate()} in that it has no
#'     \code{multiplier} argument.}
#' }
#'
#' @param numerator `numeric vector`: Dividend. Recycled to match
#'   \code{denominator} length when length-1; stops if both are
#'   length > 1 and unequal.
#' @param denominator `numeric vector`: Divisor. Recycled symmetrically.
#'   Elements where \code{abs(denominator) < zero_threshold} or
#'   \code{is.na(denominator)} are treated as zero.
#' @param default `numeric scalar`: Value substituted wherever the
#'   denominator is effectively zero (default: \code{NA_real_}).
#' @param zero_threshold `numeric scalar`: Absolute tolerance below
#'   which \code{denominator} is treated as zero
#'   (default: \code{1e-10}).  Pass \code{0} for exact integer checks.
#' @param on_zero `character(1)`: Action to take on zero denominator.
#'   One of "silent" (default), "warning", or "error". (Legacy support for
#'   silent_error_guards.R)
#' @param na_value `numeric scalar`: Alias for \code{default}. (Legacy support
#'   for calculate_retirement_cliff_statistics.R)
#'
#' @return [numeric vector] Same length as \code{denominator} (after
#'   recycling). Non-zero-denominator elements hold the quotient;
#'   zero-denominator elements hold \code{default}.
#'
#' @export
safe_divide <- function(numerator,
                        denominator,
                        default = NA_real_,
                        zero_threshold = 1e-10,
                        on_zero = c("silent", "warning", "error"),
                        na_value = NULL) {
  # Support na_value alias
  if (!is.null(na_value)) default <- na_value

  # Standardize on_zero
  on_zero <- match.arg(on_zero)

  # [HARDENING] Input Validation
  if (is.null(numerator) || is.null(denominator)) return(default)
  if (!is.numeric(numerator)) numerator <- suppressWarnings(as.numeric(numerator))
  if (!is.numeric(denominator)) denominator <- suppressWarnings(as.numeric(denominator))

  # Handle vector operations
  if (length(numerator) != length(denominator)) {
    # CYCLE 3. This used to `return(default)`, a length-1 value, for a
    # zero-length input. Inside mutate() that either errors on recycling or
    # silently lengthens a column, and the caller sees a value where there was
    # no row. Zero rows in means zero rows out.
    if (length(numerator) == 0L || length(denominator) == 0L) {
      return(rep(as.numeric(default), 0L))
    }
    if (length(numerator) == 1) {
      numerator <- rep(numerator, length(denominator))
    } else if (length(denominator) == 1) {
      denominator <- rep(denominator, length(numerator))
    } else {
      stop("Numerator and denominator must have compatible lengths", call. = FALSE)
    }
  }

  # Initialize result vector
  result <- numeric(length(numerator))

  # Identify zero/NA denominators
  zero_denom <- is.na(denominator) | abs(denominator) < zero_threshold

  # Handle zero denominator actions
  if (any(zero_denom)) {
    if (on_zero == "error") {
      stop("Division by zero encountered in safe_divide", call. = FALSE)
    } else if (on_zero == "warning") {
      warning("Division by zero encountered in safe_divide; using default", call. = FALSE)
    }
  }

  # Perform safe division
  result[!zero_denom] <- numerator[!zero_denom] / denominator[!zero_denom]
  result[zero_denom] <- default

  return(result)
}

#' @title Manuscript Alias: Safe Division
#' @export
safe_divide_manu <- function(num, den, fallback = NA_real_) {
  safe_divide(num, den, default = fallback)
}

#' @title Manuscript Alias: Safe Percentage
#' @description
#' Returns NA_real_ when the denominator is 0, NA, or NULL. This matches the
#' canonical semantics in manuscript/R/00_manuscript_utils.R. The previous
#' default = 0 caused Step 4/11 to report 0% access when the denominator was
#' missing, creating phantom care-desert artifacts (DEN-032).
#' @export
safe_pct_manu <- function(num, den, digits = 1) {
  if (is.null(num) || is.null(den)) return(NA_real_)
  safe_percent(num, den, digits = digits, default = NA_real_)
}


#' @title Safe Percentage Calculation
#' @export
safe_percent <- function(part, total, digits = 1, default = 0) {
  pct <- safe_divide(part, total, default = default / 100) * 100
  pct[is.infinite(pct) | is.nan(pct)] <- default
  round(pct, digits)
}


#' @title Safe Rate Calculation (per N)
#' @export
safe_rate <- function(events, exposure, multiplier = 1, digits = 1, default = NA_real_) {
  rate <- safe_divide(events, exposure, default = default) * multiplier
  rate[is.infinite(rate) | is.nan(rate)] <- default
  round(rate, digits)
}


#' @title Safe Ratio Calculation
#' @export
safe_ratio <- function(numerator, denominator, digits = 2, default = NA_real_) {
  ratio <- safe_divide(numerator, denominator, default = default)
  ratio[is.infinite(ratio) | is.nan(ratio)] <- default
  round(ratio, digits)
}
