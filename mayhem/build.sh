#!/usr/bin/env bash
#
# mayhem/build.sh — builds (1) the sanitized libFuzzer harness `oss-fuzz-client` (+ standalone
# reproducer) from upstream's own oss-fuzz/ harness, and (2) the project's test suite with NORMAL flags.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Project test suite (NORMAL flags, no sanitizers): cppcheck + testrunner, built in-tree via the
#    upstream Makefile (outputs are gitignored: /cppcheck, /testrunner, *.o, build/).
env -u CFLAGS -u CXXFLAGS -u LDFLAGS make -j"$MAYHEM_JOBS" CXX="$CXX" MATCHCOMPILER=yes \
    CXXFLAGS="-O1 -include stdexcept -w $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" cppcheck testrunner

# 2) Fuzz client: upstream oss-fuzz/Makefile compiles the whole analyzer (matchcompiled) instrumented.
#    Compile with fuzzer-no-link so the same objects link against libFuzzer or the standalone driver.
cd "$SRC/oss-fuzz"
make -j"$MAYHEM_JOBS" -f Makefile -f "$SRC/mayhem/objs.mk" harness-objs \
    CXX="$CXX" MATCHCOMPILER=yes LIB_FUZZING_ENGINE="-fsanitize=fuzzer-no-link" \
    CXXOPTS="-O1 -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS" \
    CPPOPTS="-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"

OBJS=$(make -s -f Makefile -f "$SRC/mayhem/objs.mk" --eval='print-objs: ; @echo $(EXTOBJ) $(LIBOBJ) main.o type2.o' MATCHCOMPILER=yes print-objs)

# lsan_off.cc: disable LeakSanitizer at build time (ASan/UBSan stay active)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $OBJS /tmp/lsan_off.o $LIB_FUZZING_ENGINE -o /mayhem/oss-fuzz-client
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $OBJS /tmp/lsan_off.o /tmp/standalone_main.o -o /mayhem/oss-fuzz-client-standalone
