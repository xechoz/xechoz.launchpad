#!/usr/bin/env bash
# Bounded, group-controlled scan runner for LocalAppLibrary.qml.
#
# Usage: scan-guard.sh <limit-bytes> <deadline-s> <grace-s> <marker> <command>
#
# The command string is run as a pipeline whose output is capped at
# <limit-bytes> *before* it reaches any consumer, so a single newline-free
# oversized record cannot be buffered without bound. The whole pipeline runs in
# its own session/process group (setsid), so the deadline can TERM then KILL the
# entire tree -- not just the direct child -- and reap it. When the cap is hit a
# final <marker> line is emitted so the caller can report truncation.
#
# Invoked as `/usr/bin/bash scan-guard.sh ...`; no executable bit required.

set -u

limit=$1
deadline=$2
grace=$3
marker=$4
command=$5

# Prefer the owner-only runtime dir for the capture file; fall back to the
# system temp dir only when it is unset. No predictable shared path is used.
tmpdir=${XDG_RUNTIME_DIR:-}
if [[ -z $tmpdir || $tmpdir != /* ]]; then tmpdir=/tmp; fi
tmp=$(/usr/bin/mktemp -p "$tmpdir") || exit 1
child=""

cleanup() {
  # Only signal a group that has not been reaped yet: after `wait` the PID is
  # freed and could be reused, so signalling it would be unsafe.
  if [[ -n $child ]]; then
    /usr/bin/kill -KILL -- "-$child" 2>/dev/null
    wait "$child" 2>/dev/null
  fi
  /usr/bin/rm -f -- "$tmp"
}
trap cleanup EXIT

# Forward a TERM/INT aimed at this wrapper (the QML backstop) to the whole
# group, then let the EXIT trap reap it.
forward() {
  if [[ -n $child ]]; then /usr/bin/kill -TERM -- "-$child" 2>/dev/null; fi
}
trap forward TERM INT

# setsid execs the pipeline directly (this wrapper is not a group leader), so
# the child's PID equals its PGID and `kill -- -PID` reaches every descendant.
/usr/bin/setsid /usr/bin/bash -c "$command | /usr/bin/head -c $((limit + 1))" >"$tmp" 2>/dev/null &
child=$!

# Deadline: TERM the group, allow a bounded grace, then KILL the group. Each
# signal is guarded by `kill -0` so a group that already exited is not signalled
# after its PID could be reused.
(
  /usr/bin/sleep "$deadline"
  if /usr/bin/kill -0 -- "-$child" 2>/dev/null; then
    /usr/bin/kill -TERM -- "-$child" 2>/dev/null
    /usr/bin/sleep "$grace"
    /usr/bin/kill -KILL -- "-$child" 2>/dev/null
  fi
) &
watchdog=$!

wait "$child" 2>/dev/null
# The group leader is reaped; clear it so the EXIT trap does not signal a
# possibly-reused PID.
child=""
/usr/bin/kill -KILL -- "-$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null

bytes=$(/usr/bin/wc -c <"$tmp")
if (( bytes > limit )); then
  /usr/bin/head -c "$limit" "$tmp"
  printf '\n%s\n' "$marker"
else
  /usr/bin/cat "$tmp"
fi
