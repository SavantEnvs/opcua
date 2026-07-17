#!/usr/bin/env bash
#
# mayhem/build.sh — build opcua's cargo-fuzz targets (fuzz_comms, fuzz_deserialize)
# as sanitized libFuzzer binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS),
# plus the opcua library test suite (normal flags) so mayhem/test.sh only RUNS it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE, resolving
# crates from the $CARGO_HOME registry this first (online) build populates. Do NOT put
# --offline here (the rlenv runtime sets CARGO_NET_OFFLINE=true for the re-run).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we pin
# it explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids ASan
# backtraces. Honor the $SANITIZER_FLAGS contract: rustc ignores the clang-oriented
# $SANITIZER_FLAGS, so we map the ASan intent to the rustc flag. ASan is the default
# halting sanitizer; an explicit empty SANITIZER_FLAGS still keeps ASan here.
SANITIZER_FLAGS="${SANITIZER_FLAGS:-}"
RUST_SANITIZER="-Zsanitizer=address"
case "$SANITIZER_FLAGS" in
  *address*|"") : ;;  # ASan requested (default) or no override
esac

# Debug-info contract (SPEC 6.2 item 10): Mayhem triage cannot read DWARF >= 4, and
# LLVM default -Cdebuginfo emits DWARF-5, so pin DWARF < 4 explicitly. Overridable via
# $RUST_DEBUG_FLAGS (the rust arm of the DEBUG_FLAGS contract verify-repo checks).
export RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SANITIZER} ${RUST_DEBUG_FLAGS} -Cforce-frame-pointers"

# libfuzzer-sys compiles a C++ runtime shim via the cc crate; clang defaults to DWARF-5,
# so pin the C/C++ objects to DWARF-3 too (the cc crate honors CFLAGS/CXXFLAGS).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# Use upstream's OWN fuzz crate (lib/fuzz) — it builds on the pinned nightly and holds
# both targets (fuzz_comms, fuzz_deserialize). No upstream files are modified.
FUZZ_DIR="lib/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# The rustc nightly ships a PRECOMPILED ASan runtime (librustc-*_rt.asan.a) whose
# compiler-rt CUs carry DWARF-5 (clang default); those runtime CUs would land in the
# linked fuzz binary and (being emitted first) fail the DWARF < 4 gate. Triage does not
# need runtime debug symbols; strip them (the archive is writable, chowned to 2000).
for _asan in $(find /opt/toolchains/rust -name "librustc-*_rt.asan.a" 2>/dev/null); do
  echo "stripping DWARF-5 debug info from runtime archive: $_asan"
  objcopy --strip-debug "$_asan" "$_asan.tmp" && mv "$_asan.tmp" "$_asan"
done

# The committed lib/fuzz/Cargo.lock pins chrono 0.4.31, which predates
# `chrono::TimeDelta` (used by opcua's date_time / secure_channel). The workspace root
# Cargo.lock already resolves chrono 0.4.38 (which has TimeDelta), so bump the fuzz
# lockfile to match — a build-time lock update (no committed upstream source is edited).
#
# IDEMPOTENT + AIR-GAPPED (SPEC 6.5): `cargo update` touches the crates.io index, which the
# offline re-run cannot reach. But the FIRST (online) build rewrites lib/fuzz/Cargo.lock to
# 0.4.38 INSIDE the image, so the offline PATCH re-run already sees a fresh-enough chrono and
# skips the update — no network. Only run cargo update when the lock is still stale.
chrono_ver="$(grep -A1 '^name = "chrono"$' "$FUZZ_DIR/Cargo.lock" 2>/dev/null | sed -n 's/^version = "\(.*\)"/\1/p' | head -1 || true)"
echo "lib/fuzz chrono lock version: ${chrono_ver:-unknown}"
case "$chrono_ver" in
  0.4.3[4-9]*|0.4.[4-9]*|0.[5-9]*|[1-9]*)
    echo "=== chrono lock already has TimeDelta (>= 0.4.34) — skipping cargo update (air-gapped re-run) ===" ;;
  *)
    echo "=== cargo update -p chrono --precise 0.4.38 (lib/fuzz lockfile — stale, bumping) ==="
    cargo update --manifest-path "$FUZZ_DIR/Cargo.toml" -p chrono --precise 0.4.38 ;;
esac

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the opcua library TEST suite with NORMAL (non-sanitized) flags so mayhem/test.sh
# only RUNS it. The types/core tests exercise the same encoding/decoding paths the
# fuzzers hit — a behavioral oracle. Clear the fuzz RUSTFLAGS for this clean build.
#
# The pinned nightly promotes the `ambiguous_glob_imports` FUTURE-INCOMPAT lint to a
# hard error (rust#114095): upstream's `opcua::types` re-exports `Argument` via two
# globs, and a server test USES the ambiguous name. This is not a real defect — the
# item is identical in both re-exports — and only bites the newer nightly, so allow
# the lint for THIS test build (a build flag, not an edit of any upstream source).
echo "=== cargo test --no-run (normal flags) ==="
RUSTFLAGS="-A ambiguous_glob_imports" cargo test --no-run -p opcua

echo "build.sh complete"
