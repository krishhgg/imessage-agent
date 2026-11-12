#!/bin/bash
# S2: self-chat sends through the spike bridge. Sends only to SELF (the user's Apple ID).
# Usage: s2.sh <self-handle> [file-kinds...]   default kinds: tmp pictures
SOCK="$HOME/Library/Application Support/iMessageAgentSpike/bridge.sock"
SELF="$1"; shift
KINDS="${*:-tmp pictures}"
op() { printf '%s\n' "$1" | nc -U "$SOCK"; }
ts() { date +%H:%M:%S; }
tok() { echo "s2-$(openssl rand -hex 4)"; }
maxrow() { op snap | sed -E 's/max_rowid=([0-9]+).*/\1/'; }
maxatt() { op snap | sed -E 's/.*max_att=([0-9]+)/\1/'; }

watch_rows() { # snap token seconds
  local last=""
  for i in $(seq 1 "$3"); do
    r=$(op "$(printf 'rows\t%s\t%s\t%s' "$1" "$SELF" "$2")")
    [ "$r" != "$last" ] && echo "$(ts) +${i}s $r" && last="$r"
    sleep 1
  done
}

echo "== warm text send"
S=$(maxrow); T=$(tok)
echo "$(ts) send: $(op "$(printf 'send\t%s\t%s' "$SELF" "S2 spike text $T")")"
watch_rows "$S" "$T" 20

for K in $KINDS; do
  echo "== file send via $K"
  S=$(maxrow); A=$(maxatt); T=$(tok)
  echo "$(ts) sendfile: $(op "$(printf 'sendfile\t%s\t%s\t%s' "$SELF" "$K" "$T")")"
  watch_rows "$S" "$T" 25
  echo "$(ts) atts: $(op "$(printf 'atts\t%s' "$A")")"
done

echo "== cold start text send"
echo "$(ts) $(op quit-messages)"
for i in $(seq 1 20); do r=$(op messages-running); [ "$r" = "running=false" ] && break; sleep 1; done
echo "$(ts) $r"
S=$(maxrow); T=$(tok)
echo "$(ts) send (cold): $(op "$(printf 'send\t%s\t%s' "$SELF" "S2 spike cold $T")")"
watch_rows "$S" "$T" 30
