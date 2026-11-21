#!/bin/sh
# check.sh - health check for the GPIO controller.
# Usage:  sh check.sh            read-only checks
#         sh check.sh --toggle   also flips the first pin through the web backend and back
D=$(cd "$(dirname "$0")" && pwd)
CONF=${CONF:-/etc/gpio-agent.conf}
[ -r "$CONF" ] || CONF="$D/gpio-agent.conf"
URL=""; KEY=""
[ -r "$CONF" ] && . "$CONF"
PASS=0; FAIL=0
ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $*"; }
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 20 "$1" 2>/dev/null; else wget -q -T 20 -O - "$1" 2>/dev/null; fi; }
pinline() { echo "$J" | sed 's/{"id"/\n{"id"/g' | grep "^{\"id\":\"$1\""; }
field() { echo "$1" | sed "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/"; }

echo "=== GPIO controller check ($(date '+%F %T')) ==="

# 1 config
if [ -n "$URL" ] && [ -n "$KEY" ]; then ok "config found ($CONF)"; else bad "URL or KEY missing in $CONF"; fi
[ "${#KEY}" -lt 20 ] && warn "KEY is short (${#KEY} chars) - use 24+ random letters/digits"

# 2 clock
Y=$(date +%Y)
if [ "$Y" -ge 2025 ]; then ok "clock looks valid ($(date '+%F %T'))"; else bad "clock wrong (year $Y) - agent sets it once online"; fi

# 3 network
IP=$(ifconfig eth0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
if [ -n "$IP" ]; then ok "eth0 has IP $IP"; else bad "eth0 has no IP (check cable; gpio-net.sh retries DHCP every 10 s)"; fi
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then ok "internet reachable (8.8.8.8)"; else bad "cannot ping 8.8.8.8"; fi
if ping -c 1 -W 3 script.google.com >/dev/null 2>&1; then ok "DNS works (script.google.com)"; else bad "cannot resolve/ping script.google.com"; fi

# 4 backend
J=$(fetch "$URL?action=status&key=$KEY")
case "$J" in
  *'"ok":true'*) ok "Google backend answers (status API)";;
  *badkey*)      bad "backend says wrong key - KEY must equal SECRET in Code.gs";;
  "")            bad "no answer from backend (network/HTTPS/URL, or deployment not set to Anyone)";;
  *)             bad "unexpected backend reply: $(echo "$J" | head -c 120)";;
esac
case "$J" in *'"online":true'*) ok "backend reports board ONLINE";; *'"ok":true'*) bad "backend reports board OFFLINE (agent not reporting yet)";; esac

# 5 gpio hardware + agent process
G=$(ls /sys/class/gpio 2>/dev/null | grep '^gpiochip' | head -n 1)
if [ -n "$G" ]; then ok "GPIO controller present ($G, base $(cat /sys/class/gpio/$G/base 2>/dev/null))"; else bad "no gpiochip in /sys/class/gpio"; fi
if ps | grep -q '[g]pio-agent.sh'; then ok "agent process is running"; else bad "agent process not running"; fi
if [ -L /etc/rc5.d/S99gpio-agent ] && [ -x /usr/local/bin/gpio-net.sh ]; then ok "installed for start at boot"; else warn "not installed for boot (run: sh $D/install.sh)"; fi

# 6 log
if [ -r /var/log/gpio-agent.log ]; then
  echo "--- last log lines ---"; tail -n 4 /var/log/gpio-agent.log; echo "----------------------"
  tail -n 1 /var/log/gpio-agent.log | grep -q 'poll failed' && bad "last log line is a failed poll"
fi

# 7 pins as seen by backend
if echo "$J" | grep -q '"ok":true'; then
  echo "--- pins (from backend) ---"
  echo "$J" | sed 's/{"id"/\n{"id"/g' | grep '^{"id"' | while read -r l; do
    echo "  $(field "$l" id): desired=$(field "$l" desired) actual=$(field "$l" actual) state=$(field "$l" state)"
  done
fi

# 8 optional round trip
if [ "$1" = "--toggle" ] && echo "$J" | grep -q '"online":true'; then
  P=$(echo "$J" | sed 's/.*"pins":\[{"id":"\([^"]*\)".*/\1/')
  cur=$(field "$(pinline "$P")" desired); new=$((1 - cur))
  echo "--- toggle test on pin '$P': $cur -> $new ---"
  fetch "$URL?action=setPin&pin=$P&value=$new&key=$KEY" >/dev/null
  done_=0; i=0
  while [ $i -lt 8 ]; do
    sleep 2; J=$(fetch "$URL?action=status&key=$KEY")
    [ "$(field "$(pinline "$P")" actual)" = "$new" ] && { done_=1; break; }
    i=$((i+1))
  done
  if [ $done_ = 1 ]; then ok "board changed '$P' to $new after about $(( (i+1)*2 )) s"; else bad "board did not confirm '$P'=$new within 16 s"; fi
  fetch "$URL?action=setPin&pin=$P&value=$cur&key=$KEY" >/dev/null && echo "      (restored '$P' to $cur)"
fi

echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" = 0 ]
