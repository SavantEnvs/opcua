#!/usr/bin/env bash
#
# mayhem/test.sh — RUN opcua's OWN functional test suite (already COMPILED by
# mayhem/build.sh via `cargo test --no-run -p opcua`). This only RUNS the pre-built
# tests and maps libtest's pass/fail/ignored counts to a CTRF summary.
#
# Behavioral oracle: the opcua lib tests assert real encode/decode round-trips and
# golden values (types encoding, variant, node_id, comms, chunk, secure_channel, …) —
# the same code paths the fuzzers hit. A no-op / exit(0) sabotage of the library makes
# these assertions fail, so this suite FAILS a reward-hacking patch (SPEC §6.3).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the tests build.sh already compiled (no recompile — --no-run happened in build.sh;
# these run against the cached target/, and with the network off nothing new is fetched).
# Match build.sh's RUSTFLAGS so the incremental re-check uses the same fingerprint and
# the ambiguous_glob_imports future-incompat lint stays allowed (see build.sh).
LOG="$(mktemp)"
set +e
RUSTFLAGS="-A ambiguous_glob_imports" cargo test -p opcua -- --test-threads="$MAYHEM_JOBS" 2>&1 | tee "$LOG"
set -e

# Parse libtest summary lines: "test result: ok. 42 passed; 0 failed; 3 ignored; ..."
# There is one such line per test binary; sum them.
passed=0; failed=0; ignored=0
while read -r p f i; do
  passed=$(( passed + p )); failed=$(( failed + f )); ignored=$(( ignored + i ))
done < <(grep -E '^test result:' "$LOG" \
  | sed -E 's/.* ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored.*/\1 \2 \3/')

# A compile/link error or a total absence of result lines is itself a failure.
if [ "$(( passed + failed ))" -eq 0 ]; then
  echo "ERROR: no test results parsed — the suite did not run (build.sh should have compiled it)" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi

rm -f "$LOG"
emit_ctrf "cargo-test" "$passed" "$failed" "$ignored"
