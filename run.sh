#!/bin/sh
# Runs the agent straight from this folder (no install needed).
#   sh run.sh        foreground with debug output; stop with Ctrl+C
#   sh run.sh bg     background (log: /var/log/gpio-agent.log), then use: sh check.sh
#   sh run.sh stop   stop a background run
D=$(cd "$(dirname "$0")" && pwd)
PIDS=/tmp/gpio-run.pids
if [ "$1" = stop ]; then
  [ -f "$PIDS" ] && kill $(cat "$PIDS") 2>/dev/null
  rm -f "$PIDS"; echo "stopped"; exit 0
fi
if ps | grep -q '[g]pio-agent.sh'; then
  echo "An agent is already running. Stop it first:"
  echo "  /etc/init.d/gpio-agent stop    (installed service)   or   sh $0 stop"
  exit 1
fi
if [ "$1" = bg ]; then
  sh "$D/gpio-net.sh" >/dev/null 2>&1 </dev/null &
  N=$!
  CONF="$D/gpio-agent.conf" sh "$D/gpio-info.sh" >/dev/null 2>&1 </dev/null &
  I=$!
  CONF="$D/gpio-agent.conf" sh "$D/gpio-agent.sh" >/dev/null 2>&1 </dev/null &
  echo "$N $I $!" > "$PIDS"
  echo "Started in background. Check with: sh $D/check.sh     Stop with: sh $0 stop"
  exit 0
fi
sh "$D/gpio-net.sh" >/dev/null 2>&1 &
CONF="$D/gpio-agent.conf" sh "$D/gpio-info.sh" >/dev/null 2>&1 &
IP_=$!
trap 'kill $NP $IP_ 2>/dev/null' INT TERM EXIT
CONF="$D/gpio-agent.conf" DEBUG=1 sh "$D/gpio-agent.sh"
