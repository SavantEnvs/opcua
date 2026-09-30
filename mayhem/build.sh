#!/usr/bin/env bash
#
# mayhem/build.sh — build opcua's fuzz-deserialize target as a sanitized libFuzzer binary
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the opcua library test suite
# (normal flags) so mayhem/test.sh only RUNS it.
#
# At this vulnerable commit upstream had not yet consolidated its fuzz targets into a single
# lib/fuzz crate (that happened later); the per-module fuzz crate this commit ships
# (lib/src/types/fuzz) depends on crates ("opcua-types", "opcua-console-logging") that were
# already gone from the tree by this point and does not build. Rather than edit that upstream
# fuzz crate, this backport ships its OWN, purely-additive fuzz-deserialize crate under
# mayhem/ — a path dependency on the real "opcua" lib crate, reconstructed from the
# mayhemheroes fork's own harness fix for this exact target/commit (BACKPORT.md, Watch fors).
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

# Our own additive fuzz crate (see header comment) — one target, fuzz_deserialize.
FUZZ_DIR="mayhem/fuzz-deserialize"
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

# This fuzz crate has no committed Cargo.lock (it is a new, purely-additive crate — see
# header comment), so a fresh resolve floats chrono to latest, which renamed its `Duration`
# to `TimeDelta` (keeping `Duration` as an alias) — but that rename lands the SERVER
# subscription code (comparing a chrono `Duration` field against a `TimeDelta` returned by
# a newer chrono API) in a real type mismatch at this 2022-era commit. Pin chrono to 0.4.31,
# the last version before that rename (matches the pin the live mayhem branch's own
# lib/fuzz/Cargo.lock carries for the same reason). `cargo update` needs network for the
# index; the FIRST (online) build does this once and the resulting lockfile makes the
# offline PATCH re-run idempotent (SPEC §6.5).
if [ ! -f "$FUZZ_DIR/Cargo.lock" ] || ! grep -q '^version = "0.4.31"$' "$FUZZ_DIR/Cargo.lock" 2>/dev/null; then
  echo "=== cargo update -p chrono --precise 0.4.31 ($FUZZ_DIR — pin pre-TimeDelta chrono) ==="
  cargo update --manifest-path "$FUZZ_DIR/Cargo.toml" -p chrono --precise 0.4.31
fi

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
# -D (dev/unoptimized, debug-assertions on by default) — NOT -O: the recursive
# Variant/DataValue decode this target's bug lives in (unbounded recursion, no depth
# limit) needs far MORE stack per recursion level to overflow than an optimized build
# uses (LLVM's inlining/stack coalescing on this 2025 nightly shrinks each recursive
# frame a lot vs. whatever toolchain the original 2022 mayhemheroes run used). Built -O,
# the original run's saved crashers (a few KB each) no longer reach the stack limit at
# all; built -D, they overflow again at the SAME recursion (same functions in the
# backtrace) the original run found — see BACKPORT.md, Watch fors.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -D "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/debug/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the behavioral oracle (mayhem/oracle) with NORMAL (non-sanitized) flags so
# mayhem/test.sh only RUNS it — a known-input/known-output Variant round trip through the
# same codec fuzz_deserialize exercises. NOT `cargo test -p opcua`: that package's own
# dev-dependency rustc-serialize 0.3.24 (unmaintained since ~2016) fails to compile under
# any modern rustc (E0310), so building any test binary for the whole crate is impossible
# on this toolchain, unrelated to opcua's own code or this target.
echo "=== cargo build --release (oracle, normal flags) ==="
RUSTFLAGS= CFLAGS= CXXFLAGS= cargo build --manifest-path mayhem/oracle/Cargo.toml --release
[ -x "mayhem/oracle/target/release/oracle" ] || { echo "ERROR: expected oracle binary not found" >&2; exit 1; }
cp mayhem/oracle/target/release/oracle /mayhem/oracle

echo "build.sh complete"
