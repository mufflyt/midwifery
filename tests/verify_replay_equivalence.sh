#!/bin/sh
# =============================================================================
# Replay equivalence: does coverage give the same answer with and without
# replayed evidence, and does it reject evidence that does not belong?
# =============================================================================
# WHY THIS IS A FILE AND NOT A TRANSCRIPT. tests/ci_law_coverage.R replays gate
# output from LAW_EVIDENCE_DIR instead of re-running every gate, because at ten
# laws re-running them took the gate past its own 600s budget. That is a
# correctness claim -- "the replayed answer is the answer you would have got" --
# and it was verified once, by hand, in a scratch directory that no longer
# exists. A property nobody else can re-check is a property that has already
# started to rot. DEBT.md exists for exactly this reason and says so.
#
# Two earlier attempts at this experiment were VOID, and the way they failed is
# the reason this script pins a commit and works in its own tree: both were
# launched in the background against the working tree, and then the tree was
# edited underneath them. The no-replay leg took 523s in one clean run and 303s
# in another -- long enough that "just run it here" is never safe.
#
# WHAT IT PROVES
#
#   1. EQUIVALENCE. Coverage run with replayed evidence must produce the same
#      exit status and the same scoreboard as coverage that executes every gate.
#   2. CUSTODY. A well-formed, green log whose stamp does not match the sources
#      being evaluated must be REJECTED, not used. This is the stronger claim,
#      and the one that fails silently if it ever regresses: a stale log carries
#      exactly the markers coverage is looking for.
#
# WHAT IT COSTS. The no-replay leg runs every registered gate and every mutation
# harness. Budget 10-15 minutes and expect it to be dominated by the L8/L9
# determinism harness, which runs its suite six times.
#
# USAGE
#   tests/verify_replay_equivalence.sh [commit-ish]      (default: HEAD)
#
# L5 NEEDS A GITIGNORED SURFACE (DEBT.md D7). A clean worktree does not have
# artifacts/maps/, so L5 cannot run there. It is copied in from the invoking
# checkout when present, and its absence is reported rather than worked around
# -- a run where L5 skipped is still a valid equivalence test, because both legs
# skip it identically, but it is not the same experiment and should not be
# reported as one.
# =============================================================================
set -u

REPO=$(git rev-parse --show-toplevel) || exit 1
REF=${1:-HEAD}
SHA=$(git -C "$REPO" rev-parse "$REF") || exit 1
WT=$(mktemp -d "${TMPDIR:-/tmp}/mw-replay-XXXXXX")
OUT=$(mktemp -d "${TMPDIR:-/tmp}/mw-replay-out-XXXXXX")
EV="$OUT/evidence"
mkdir -p "$EV"

cleanup() {
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$REPO" worktree prune >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

echo "commit under test : ${SHA%${SHA#????????}}"
echo "isolated worktree : $WT"

git -C "$REPO" worktree add -q --detach "$WT" "$SHA" || {
  echo "FAIL: could not create an isolated worktree"; exit 1; }

# The registry is the only thing that decides what a law is, so the gate list is
# read from it rather than restated here. A law added tomorrow is covered by
# this script today.
REG="$WT/tests/science_law_registry.tsv"
GATES=$(awk -F'\t' '!/^#/ && NF > 1 && $1 != "law" { print $3; print $4 }' "$REG" \
        | sort -u)
echo "gates to exercise : $(echo "$GATES" | wc -l | tr -d ' ')"

if [ -d "$REPO/artifacts/maps" ]; then
  mkdir -p "$WT/artifacts/maps"
  cp "$REPO"/artifacts/maps/*.rds "$WT/artifacts/maps/" 2>/dev/null
  echo "L5 surfaces       : $(ls "$WT/artifacts/maps" 2>/dev/null | wc -l | tr -d ' ') copied in"
else
  echo "L5 surfaces       : ABSENT -- L5 will skip in BOTH legs (see DEBT.md D7)"
fi

# --- generate evidence exactly as the nightly does ---------------------------
echo
echo "generating evidence..."
( cd "$WT" && LAW_RUN_ID=replay-equivalence sh -c '
  for f in '"$(echo "$GATES" | tr '\n' ' ')"'; do
    [ -f "$f" ] && Rscript "$f" > "'"$EV"'/$(basename "$f").log" 2>&1
  done' )
echo "  $(ls "$EV" | wc -l | tr -d ' ') logs"

run_leg() {
  _label=$1; _out=$2; shift 2
  _start=$(date +%s)
  ( cd "$WT" && env "$@" Rscript tests/ci_law_coverage.R ) > "$_out" 2>&1
  _rc=$?
  echo "$_label rc=$_rc $(( $(date +%s) - _start ))s"
  return $_rc
}

echo
run_leg "no-replay" "$OUT/norep.txt" DUMMY=1; RC_A=$?
run_leg "replay   " "$OUT/rep.txt" LAW_EVIDENCE_DIR="$EV"; RC_B=$?

sed -n '/Scientific laws declared/,/Unexpected skips/p' "$OUT/norep.txt" > "$OUT/a.txt"
sed -n '/Scientific laws declared/,/Unexpected skips/p' "$OUT/rep.txt"   > "$OUT/b.txt"

echo
FAILED=0
if [ "$RC_A" -eq "$RC_B" ] && cmp -s "$OUT/a.txt" "$OUT/b.txt"; then
  echo "PASS  equivalence: identical exit status and identical scoreboard"
else
  echo "FAIL  equivalence: replay does not agree with direct execution"
  diff "$OUT/a.txt" "$OUT/b.txt"
  FAILED=1
fi
cat "$OUT/a.txt"

# --- custody: corrupt one stamp and require rejection ------------------------
# Only the recorded source hash is altered. The log stays well-formed and still
# says everything passed, which is the whole point: this is what a green log
# from a commit where the gate differed looks like.
echo
VICTIM=$(ls "$EV" | head -1)
if [ -n "$VICTIM" ]; then
  perl -pi -e 's/(\[EVIDENCE\].*src_md5=)[0-9a-f]+/${1}00000000000000000000000000000000/' \
       "$EV/$VICTIM"
  ( cd "$WT" && LAW_EVIDENCE_DIR="$EV" Rscript tests/ci_law_coverage.R ) \
      > "$OUT/stale.txt" 2>&1
  if [ $? -ne 0 ] && grep -q "not evidence for this evaluation" "$OUT/stale.txt"; then
    echo "PASS  custody: a stale-but-green log is rejected, not used"
    grep -m1 "not evidence for this evaluation" "$OUT/stale.txt" | sed 's/^/      /'
  else
    echo "FAIL  custody: coverage ACCEPTED evidence that does not match the tree"
    FAILED=1
  fi
else
  echo "FAIL  custody: no evidence was generated, so nothing was tested"
  FAILED=1
fi

echo
[ "$FAILED" -eq 0 ] && echo "OK" || echo "FAILED"
exit "$FAILED"
