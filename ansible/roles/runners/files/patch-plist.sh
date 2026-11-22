#!/bin/bash
# Bring a runner LaunchAgent plist (or its template) to the three values the runners need.
# Prints "patched" when it changed the file and "ok" when it was already right; any other
# exit is a failure (a missing or unreadable file is never treated as "already right").
#   SessionCreate=false   true keeps Claude from reading the login keychain
#   KeepAlive=true        the listener exits on a non-retryable error (expired session after a
#                         long offline period) and runsvc.sh returns 0, so launchd must restart it
#   ThrottleInterval=60   at most one restart a minute, e.g. while the registration is gone
set -euo pipefail
f="$1"
[ -f "${f}" ] || { echo "${f}: not found" >&2; exit 1; }
changed=0
want() { # want <key> <type> <value>
  local cur
  cur="$(plutil -extract "$1" raw -o - "${f}" 2>/dev/null || true)"
  if [ "${cur}" != "$3" ]; then
    plutil -replace "$1" "-$2" "$3" "${f}"
    changed=1
  fi
}
want SessionCreate bool false
want KeepAlive bool true
want ThrottleInterval integer 60
if [ "${changed}" = 1 ]; then echo patched; else echo ok; fi
