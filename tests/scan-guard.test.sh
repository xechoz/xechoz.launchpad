#!/usr/bin/env bash
# Tests for scan-guard.sh: the producer-side byte cap and the process-group
# deadline. Run: bash tests/scan-guard.test.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
guard="$here/../scan-guard.sh"
marker="__launchpad_scan_truncated__"
failures=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }

# A: a single newline-free record larger than the cap must be bounded before it
# reaches any parser, and the truncation marker must be reported.
limit=1024
out=$(/usr/bin/bash "$guard" "$limit" 10 2 "$marker" \
  '/usr/bin/head -c 1048576 /dev/zero | /usr/bin/tr "\0" x')
bytes=$(printf '%s' "$out" | /usr/bin/wc -c)
if (( bytes <= limit + ${#marker} + 2 )); then
  pass "newline-free record capped (${bytes} bytes <= ${limit} + marker)"
else
  fail "newline-free record not capped (${bytes} bytes)"
fi
if printf '%s\n' "$out" | /usr/bin/grep -qxF "$marker"; then
  pass "truncation marker emitted"
else
  fail "truncation marker missing"
fi

# B: a child that ignores TERM must still be killed by the group KILL, and the
# guard must return promptly rather than waiting out the child.
victim="launchpad-test-victim-$$"
start=$(date +%s)
/usr/bin/bash "$guard" 1024 1 1 "$marker" \
  "/usr/bin/bash -c 'trap \"\" TERM; exec -a $victim /usr/bin/sleep 60'" >/dev/null
elapsed=$(( $(date +%s) - start ))
if (( elapsed < 10 )); then
  pass "deadline returned promptly (${elapsed}s)"
else
  fail "deadline did not return promptly (${elapsed}s)"
fi
if /usr/bin/pgrep -f "$victim" >/dev/null; then
  fail "TERM-ignoring child survived the group KILL"
  /usr/bin/pkill -9 -f "$victim" 2>/dev/null
else
  pass "TERM-ignoring child killed with the group"
fi

if (( failures == 0 )); then
  printf '\nall tests passed\n'
else
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
