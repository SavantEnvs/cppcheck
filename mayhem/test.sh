#!/usr/bin/env bash
#
# mayhem/test.sh — RUN cppcheck's own testrunner (built by mayhem/build.sh) plus known-answer probes.
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# 1) Known-answer probes: run the built cppcheck on fixed inputs and assert the exact diagnostics.
#    (A neutered/no-op cppcheck prints nothing and fails here.)
[ -x ./cppcheck ] || { echo "missing ./cppcheck (build.sh bug)" >&2; emit_ctrf "cppcheck-testrunner" 0 1 0; exit 1; }
[ -x ./testrunner ] || { echo "missing ./testrunner (build.sh bug)" >&2; emit_ctrf "cppcheck-testrunner" 0 1 0; exit 1; }
kat_pass=0 ; kat_fail=0
kat() {  # kat <name> <expected-output> <source-text>
  local name="$1" want="$2" src="$3" dir got
  dir=$(mktemp -d)
  printf '%s\n' "$src" > "$dir/in.c"
  got=$(./cppcheck -q --enable=warning --template='{line}:{id}:{message}' "$dir/in.c" 2>&1)
  rm -rf "$dir"
  if [ "$got" = "$want" ]; then kat_pass=$((kat_pass+1)); else
    kat_fail=$((kat_fail+1)); echo "KAT $name FAILED: got [$got] want [$want]" >&2; fi
}
kat array-oob "3:arrayIndexOutOfBounds:Array 'a[10]' accessed at index 10, which is out of bounds." \
'int main() {
    char a[10];
    a[10] = 0;
    return 0;
}'
kat null-deref "3:nullPointerRedundantCheck:Either the condition '!p' is redundant or there is possible null pointer dereference: p." \
'void f(int *p) {
    if (!p) {}
    *p = 1;
}'
kat clean "" \
'int main() {
    return 0;
}'

# 2) Upstream's own unit-test runner (all fixtures); parse its summary and assert it ran.
out=$(./testrunner -q 2>&1) ; rc=$?
printf '%s\n' "$out" | tail -8
n=$(printf '%s\n' "$out" | sed -n 's/^Number of tests: \([0-9][0-9]*\)$/\1/p' | tail -1)
f=$(printf '%s\n' "$out" | sed -n 's/^Tests failed: \([0-9][0-9]*\)$/\1/p' | tail -1)
if [ -z "$n" ] || [ -z "$f" ] || [ "$n" -lt 1000 ]; then
  echo "testrunner produced no valid summary (rc=$rc)" >&2
  emit_ctrf "cppcheck-testrunner" "$kat_pass" $((kat_fail + 1)) 0
  exit 1
fi
[ "$rc" -eq 0 ] || f=$((f > 0 ? f : 1))
passed=$((n - f))
emit_ctrf "cppcheck-testrunner" $((passed + kat_pass)) $((f + kat_fail)) 0
