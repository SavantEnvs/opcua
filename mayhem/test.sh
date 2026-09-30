#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the behavioral oracle (already COMPILED by mayhem/build.sh at
# /mayhem/oracle): a known-input/known-output round trip through opcua's own Variant binary
# codec, the same code path fuzz_deserialize exercises. Maps its pass/fail to a CTRF summary.
#
# NOT `cargo test -p opcua`: that package's own dev-dependency rustc-serialize 0.3.24
# (unmaintained since ~2016) fails to compile under any modern rustc (E0310), unrelated to
# opcua's own code or this target (see build.sh). A no-op / exit(0) sabotage of the library's
# Variant encode/decode makes the oracle's assertions fail, so it FAILS a reward-hacking patch
# (SPEC §6.3).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
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

# Check the ORACLE'S OWN OUTPUT, not just its exit code (§6.3): a sabotaged binary that never
# reaches main() (e.g. an LD_PRELOAD constructor that _exit(0)s before any code runs) still exits
# 0, so an exit-code-only check is reward-hackable. The success line below is only ever printed
# AFTER every known-input/known-output assertion in mayhem/oracle/src/main.rs has passed.
OUT="$(/mayhem/oracle 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'known-input/known-output Variant round trip OK'; then
  emit_ctrf "opcua-oracle" 1 0
else
  echo "$OUT" >&2
  emit_ctrf "opcua-oracle" 0 1
fi
