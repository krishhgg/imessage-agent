#!/bin/bash
# Waits for the user to grant FDA and Automation to the spike, logging each transition.
# Reads only the TCC rows for the spike's bundle id, never message content.
HERE="$(cd "$(dirname "$0")" && pwd)"
SYS="/Library/Application Support/com.apple.TCC/TCC.db"
USR="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
ts() { date +%H:%M:%S; }
row() { sqlite3 -readonly "$1" "select auth_value from access where client='local.imessageagent.spike' and service='$2'" 2>/dev/null; }

echo "$(ts) ae: $("$HERE/spike" ae)" &
AE_PID=$!

fda_seen=""
for i in $(seq 1 300); do
  v=$(row "$SYS" kTCCServiceSystemPolicyAllFiles)
  if [ "$v" = "2" ] && [ -z "$fda_seen" ]; then
    fda_seen=1
    echo "$(ts) tcc fda row=2"
    for j in 1 2 3 4 5; do
      s=$("$HERE/spike" status 2>&1); echo "$(ts) status (no restart, try $j): $s"
      case "$s" in *message_rows*) break;; esac
      sleep 2
    done
    case "$s" in *message_rows*) ;; *)
      echo "$(ts) kickstart -k"; launchctl kickstart -k "gui/$(id -u)/local.imessageagent.spike"; sleep 2
      echo "$(ts) status (after restart): $("$HERE/spike" status 2>&1)";;
    esac
    echo "$(ts) whoami: $("$HERE/spike" whoami)"
  fi
  if [ -n "$fda_seen" ] && ! kill -0 $AE_PID 2>/dev/null; then break; fi
  sleep 2
done
wait $AE_PID 2>/dev/null
echo "$(ts) automation row: $(row "$USR" kTCCServiceAppleEvents)"
echo "$(ts) ae-script: $("$HERE/spike" ae-script)"
