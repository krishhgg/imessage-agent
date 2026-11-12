#!/bin/bash
# Waits for the FDA grant, then checks whether the running bridge sees it before and after a restart.
HERE="$(cd "$(dirname "$0")" && pwd)"
SYS="/Library/Application Support/com.apple.TCC/TCC.db"
ts() { date +%H:%M:%S; }
for i in $(seq 1 270); do
  v=$(sqlite3 -readonly "$SYS" "select auth_value from access where client='local.imessageagent.spike' and service='kTCCServiceSystemPolicyAllFiles'" 2>/dev/null)
  if [ "$v" = "2" ]; then
    echo "$(ts) tcc fda row=2; bridge before: $("$HERE/spike" whoami | sed -E 's/.*pid=([0-9]+) ppid.*/pid=\1/')"
    for j in 1 2 3; do s=$("$HERE/spike" status); echo "$(ts) status no restart try $j: $s"; case "$s" in *message_rows*) break;; esac; sleep 2; done
    case "$s" in *message_rows*) ;; *) launchctl kickstart -k "gui/$(id -u)/local.imessageagent.spike"; sleep 2; echo "$(ts) status after kickstart -k: $("$HERE/spike" status)";; esac
    echo "$(ts) whoami: $("$HERE/spike" whoami | cut -c1-90)"
    exit 0
  fi
  sleep 2
done
echo "$(ts) timed out, fda row=$v"
