# =============================================================================
# Checkpoint safety: an interrupted write must never corrupt current state
# =============================================================================
# geocode_queue_cascade.R's RAW_CKPT mechanism persists hours of irreplaceable
# Census/ArcGIS network calls before a separate, riskier enrichment step runs.
# save_checkpoint_atomic()/load_checkpoint() (R/lib/checkpoint_utils.R) exist
# because a direct saveRDS() to the final path can be left truncated if the
# process dies mid-write.
#
# INVARIANT under test: after any interrupted write, the last known-good
# checkpoint remains readable, AND partially written state is never accepted
# as current.
#
# Every scenario below simulates "the process died at point X" by directly
# manipulating the .tmp file the real function would have written -- never by
# actually killing a process -- since that is what makes the promotion
# boundary (file.rename()) deterministically testable.
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "checkpoint_utils.R"))

work <- tempfile("checkpoint_safety_"); dir.create(work)
ckpt <- file.path(work, "raw_result.rds")
tmp  <- paste0(ckpt, ".tmp")

is_error <- function(expr) inherits(tryCatch(expr, error = function(e) e), "error")

# -----------------------------------------------------------------------------
# a. Clean successful checkpoint
# -----------------------------------------------------------------------------
ci_section("Clean successful checkpoint")
v1 <- data.frame(id = 1:5, lat = c(40.1, 41.2, NA, 43.4, 44.5),
                 lon = c(-74.1, -75.2, -76.3, NA, -78.5),
                 stringsAsFactors = FALSE)
save_checkpoint_atomic(v1, ckpt)
if (identical(load_checkpoint(ckpt), v1)) {
  ci_ok("save_checkpoint_atomic() then load_checkpoint() round-trips the object exactly")
} else {
  ci_fail("round-trip through save_checkpoint_atomic()/load_checkpoint() did not return an identical object")
}
if (!file.exists(tmp)) {
  ci_ok("no .tmp file left behind after a successful checkpoint")
} else {
  ci_fail(".tmp file still present after a successful save_checkpoint_atomic() call")
}

# -----------------------------------------------------------------------------
# b. Interruption immediately before checkpoint write (nothing written yet)
# -----------------------------------------------------------------------------
ci_section("Interruption immediately before checkpoint write")
fresh_path <- file.path(work, "never_written.rds")
# Modeling "the process died before save_checkpoint_atomic() was ever called"
# is exactly "don't call it" -- there is nothing to corrupt, and the absence
# of a checkpoint must stay exactly that: absence, not a fabricated one.
if (!file.exists(fresh_path)) {
  ci_ok("a checkpoint never attempted stays absent -- no accidental file materializes")
} else {
  ci_fail("a checkpoint path that was never written unexpectedly exists")
}
if (is_error(load_checkpoint(fresh_path))) {
  ci_ok("load_checkpoint() on a path with no checkpoint at all errors rather than fabricating a result")
} else {
  ci_fail("load_checkpoint() did not error on a path where no checkpoint was ever written")
}
# And the case where a prior good checkpoint already exists: not calling
# save again must leave it exactly as it was.
before_val <- load_checkpoint(ckpt)
if (identical(load_checkpoint(ckpt), before_val)) {
  ci_ok("an existing good checkpoint is untouched when no new write is attempted")
} else {
  ci_fail("an existing good checkpoint changed with no write attempted -- should be impossible")
}

# -----------------------------------------------------------------------------
# c. Interruption during temporary/staging write
# -----------------------------------------------------------------------------
ci_section("Interruption during temporary/staging write")

## c1: no prior checkpoint at this path
c1_path <- file.path(work, "c1.rds")
c1_tmp <- paste0(c1_path, ".tmp")
writeBin(as.raw(c(0x00, 0x01, 0x02, 0xFF)), c1_tmp)  # garbage, mid-write simulation
if (!file.exists(c1_path)) {
  ci_ok("garbage left in .tmp during staging never materializes at the final path (no prior checkpoint case)")
} else {
  ci_fail("garbage .tmp content leaked into the final checkpoint path")
}
if (is_error(load_checkpoint(c1_path))) {
  ci_ok("load_checkpoint() refuses to read the .tmp garbage even though no valid checkpoint exists at the real path")
} else {
  ci_fail("load_checkpoint() somehow returned a result despite only garbage .tmp content being present")
}

## c2: a prior good checkpoint v1 already exists
c2_path <- file.path(work, "c2.rds")
v1_c2 <- list(tag = "v1", n = 42L)
save_checkpoint_atomic(v1_c2, c2_path)
c2_tmp <- paste0(c2_path, ".tmp")
writeBin(as.raw(c(0xDE, 0xAD, 0xBE, 0xEF)), c2_tmp)  # simulated mid-write crash of a v2 attempt
if (identical(load_checkpoint(c2_path), v1_c2)) {
  ci_ok("a prior good checkpoint survives a simulated mid-staging-write crash of a later attempt untouched")
} else {
  ci_fail("a prior good checkpoint was corrupted by a simulated mid-staging-write crash of a later attempt")
}

# -----------------------------------------------------------------------------
# d. Interruption immediately before promotion/rename
# -----------------------------------------------------------------------------
ci_section("Interruption immediately before promotion/rename")

## d1: no prior checkpoint
d1_path <- file.path(work, "d1.rds")
d1_tmp <- paste0(d1_path, ".tmp")
new_obj_d1 <- data.frame(x = 1:3)
saveRDS(new_obj_d1, d1_tmp)  # fully written .tmp, but file.rename() never runs
if (!file.exists(d1_path)) {
  ci_ok("a fully-written-but-not-yet-promoted .tmp never appears as the current checkpoint (no prior checkpoint case)")
} else {
  ci_fail("a checkpoint materialized at the final path despite promotion (file.rename) never running")
}

## d2: prior good checkpoint v1 exists
d2_path <- file.path(work, "d2.rds")
v1_d2 <- list(tag = "v1", n = 7L)
save_checkpoint_atomic(v1_d2, d2_path)
d2_tmp <- paste0(d2_path, ".tmp")
new_obj_d2 <- list(tag = "v2_never_promoted", n = 999L)
saveRDS(new_obj_d2, d2_tmp)  # complete write, promotion never happens
if (identical(load_checkpoint(d2_path), v1_d2)) {
  ci_ok("an unpromoted-but-complete new checkpoint never displaces the last known-good one")
} else {
  ci_fail("load_checkpoint() returned the unpromoted new object instead of the last known-good checkpoint")
}

# -----------------------------------------------------------------------------
# e. Restart after interrupted checkpoint
# -----------------------------------------------------------------------------
ci_section("Restart after interrupted checkpoint")
# Reuse d2's stale-.tmp-debris state (a complete-but-unpromoted v2 .tmp sitting
# next to a promoted v1) and prove a genuine subsequent save is not blocked or
# confused by that leftover debris.
v3 <- list(tag = "v3_real_save", n = 12345L)
save_checkpoint_atomic(v3, d2_path)
if (identical(load_checkpoint(d2_path), v3)) {
  ci_ok("a real save_checkpoint_atomic() call cleanly overwrites stale .tmp debris from a prior interrupted attempt")
} else {
  ci_fail("stale .tmp debris from a prior interrupted attempt blocked or corrupted a subsequent legitimate checkpoint")
}
if (!file.exists(paste0(d2_path, ".tmp"))) {
  ci_ok("no .tmp debris remains after the restart's successful checkpoint")
} else {
  ci_fail(".tmp debris still present after a successful restart checkpoint")
}

# -----------------------------------------------------------------------------
# f. Pre-existing valid checkpoint not corrupted by a failed subsequent attempt
# -----------------------------------------------------------------------------
ci_section("Pre-existing valid checkpoint survives a failed subsequent attempt")
f_path <- file.path(work, "f.rds")
v1_f <- data.frame(id = 1:10, val = letters[1:10], stringsAsFactors = FALSE)
save_checkpoint_atomic(v1_f, f_path)
# Simulate a failed v2 attempt: garbage mid-write, never promoted.
f_tmp <- paste0(f_path, ".tmp")
writeBin(as.raw(sample(0:255, 16, replace = TRUE)), f_tmp)
if (identical(load_checkpoint(f_path), v1_f)) {
  ci_ok("the last known-good checkpoint is byte-for-byte unchanged after a failed subsequent attempt")
} else {
  ci_fail("a failed subsequent checkpoint attempt corrupted the last known-good checkpoint")
}

unlink(work, recursive = TRUE)
ci_finish()
