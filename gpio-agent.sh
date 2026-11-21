#!/bin/sh
# gpio-agent.sh - polls the Google Apps Script web app and drives GPIOs.
# POSIX sh / BusyBox ash compatible. Install as /usr/local/bin/gpio-agent.sh
# Pins come from the server (the PINS list in Code.gs) - nothing pin-specific lives here.
# Debug in the foreground:  DEBUG=1 /usr/local/bin/gpio-agent.sh

CONF=${CONF:-/etc/gpio-agent.conf}
LOG=/var/log/gpio-agent.log
STATE=/var/run/gpio-agent
SYSFS=/sys/class/gpio
LEDS=/sys/class/leds
DBG=/sys/kernel/debug/gpio
INTERVAL=2
INSECURE=0
URL=""
KEY=""

[ -r "$CONF" ] && . "$CONF"
if [ -z "$URL" ] || [ -z "$KEY" ]; then
  echo "gpio-agent: set URL and KEY in $CONF" >&2
  exit 1
fi

log() {
  [ -n "$DEBUG" ] && echo "$*"
  echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null
  sz=$(wc -c < "$LOG" 2>/dev/null)
  [ "${sz:-0}" -gt 100000 ] && mv -f "$LOG" "$LOG.1"
}

# ---------------------------------------------------------------- HTTP tool
if command -v curl >/dev/null 2>&1; then HTTP=curl
elif command -v wget >/dev/null 2>&1; then HTTP=wget
else log "FATAL: neither curl nor wget found"; exit 1
fi
CURL_OPTS="-fsSL --max-time 20"      # -L follows the Apps Script redirect
WGET_OPTS="-q -T 20"                 # wget follows redirects by default
if [ "$INSECURE" = 1 ]; then
  CURL_OPTS="$CURL_OPTS -k"
  wget --help 2>&1 | grep -q 'no-check-certificate' && WGET_OPTS="$WGET_OPTS --no-check-certificate"
fi

fetch() {
  if [ "$HTTP" = curl ]; then curl $CURL_OPTS "$1" 2>/dev/null
  else wget $WGET_OPTS -O - "$1" 2>/dev/null
  fi
}

# ---------------------------------------------------------------- clock
year_ok() { [ "$(date +%Y)" -ge 2025 ]; }
uptime_s() { read -r u _ < /proc/uptime; echo "${u%.*}"; }

set_clock() {
  date -u -s "$1" >/dev/null 2>&1
  if year_ok; then log "clock set to $1 UTC"; return 0; fi
  return 1
}

http_date() {   # plain HTTP (no certificate needed) -> the Date: header
  if [ "$HTTP" = curl ]; then curl -sI -m 10 http://www.google.com 2>/dev/null
  else wget -S -O /dev/null -T 10 http://www.google.com 2>&1
  fi | grep -i '^ *date:' | head -n 1
}

sync_time() {
  year_ok && return 0
  if command -v ntpd >/dev/null 2>&1; then
    T=""
    command -v timeout >/dev/null 2>&1 && T="timeout 20"
    $T ntpd -q -n -p pool.ntp.org -p time.google.com >/dev/null 2>&1
    if year_ok; then log "clock set by ntpd"; return 0; fi
  fi
  line=$(http_date | tr -d '\r')
  set -- $line          # Date: Fri, 20 Nov 2026 17:35:00 GMT
  case "$4" in
    Jan) m=01;; Feb) m=02;; Mar) m=03;; Apr) m=04;; May) m=05;; Jun) m=06;;
    Jul) m=07;; Aug) m=08;; Sep) m=09;; Oct) m=10;; Nov) m=11;; Dec) m=12;;
    *) log "clock: could not get time (no ntpd result, no HTTP Date header)"; return 1;;
  esac
  set_clock "$5-$m-$3 $6"
}

# ---------------------------------------------------------------- gpiochip discovery
CHIP_BASE=""; CHIP_N=""
find_chip() {
  first_c=""
  for c in "$SYSFS"/gpiochip*; do
    [ -d "$c" ] || continue
    [ -z "$first_c" ] && first_c=$c
    lbl=$(cat "$c/label" 2>/dev/null)
    case "$lbl" in
      *zynq*) CHIP_BASE=$(cat "$c/base"); CHIP_N=$(cat "$c/ngpio")
              log "gpiochip: $c label=$lbl base=$CHIP_BASE ngpio=$CHIP_N"; return 0;;
    esac
  done
  if [ -n "$first_c" ]; then
    CHIP_BASE=$(cat "$first_c/base"); CHIP_N=$(cat "$first_c/ngpio")
    log "gpiochip: no zynq label, using $first_c base=$CHIP_BASE ngpio=$CHIP_N"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- pin handling
# Real pin level from the kernel's debugfs (it reads the hardware). Prints 1/0 as the
# LOGICAL value (inverted for ACTIVE LOW lines). Prints nothing if unavailable.
hw_value() {
  hv_n=$1
  [ -r "$DBG" ] || return 1
  hv_line=$(grep "gpio-$hv_n " "$DBG" 2>/dev/null | head -n 1)
  [ -n "$hv_line" ] || return 1
  hv_rest=${hv_line#*) }
  hv_inv=0
  case "$hv_rest" in *"ACTIVE LOW"*) hv_inv=1;; esac
  set -- $hv_rest
  case "$2" in
    hi) [ "$hv_inv" = 1 ] && echo 0 || echo 1;;
    lo) [ "$hv_inv" = 1 ] && echo 1 || echo 0;;
    *) return 1;;
  esac
}

read_val() {   # mode vfile n  -> 0 | 1 | E
  rv=$(hw_value "$3")
  [ -z "$rv" ] && rv=$(cat "$2" 2>/dev/null)
  case "$rv" in
    0|1) echo "$rv";;
    ''|*[!0-9]*) echo E;;
    *) echo 1;;
  esac
}

setup_pin() {  # id gpio dir led   -> writes $STATE/<id>.dat as  mode|value-file|linux-gpio
  sp_id=$1; sp_gpio=$2; sp_dir=$3; sp_led=$4
  sp_fail() { log "pin $sp_id: $1"; echo "ERR||" > "$STATE/$sp_id.dat"; }

  case "$sp_gpio" in ''|*[!0-9]*) sp_fail "bad gpio '$sp_gpio'"; return;; esac
  case "$sp_dir" in in|out) ;; *) sp_fail "bad direction '$sp_dir'"; return;; esac
  if [ "$sp_gpio" -ge "$CHIP_N" ]; then sp_fail "gpio $sp_gpio outside chip (0-$((CHIP_N-1)))"; return; fi
  sp_n=$((CHIP_BASE + sp_gpio))

  # Pins owned by the kernel's gpio-leds driver: drive them through /sys/class/leds
  if [ "$sp_dir" = out ] && [ -n "$sp_led" ] && [ -w "$LEDS/$sp_led/brightness" ]; then
    [ -w "$LEDS/$sp_led/trigger" ] && echo none > "$LEDS/$sp_led/trigger" 2>/dev/null
    echo 0 > "$LEDS/$sp_led/brightness" 2>/dev/null
    echo "led|$LEDS/$sp_led/brightness|$sp_n" > "$STATE/$sp_id.dat"
    log "pin $sp_id: LED '$sp_led' (linux gpio $sp_n) -> output, OFF"
    return
  fi

  # Plain sysfs GPIO
  [ -d "$SYSFS/gpio$sp_n" ] || echo "$sp_n" > "$SYSFS/export" 2>/dev/null
  if [ ! -d "$SYSFS/gpio$sp_n" ]; then
    sp_fail "cannot export linux gpio $sp_n (owned by a kernel driver? add led='name' in PINS)"
    return
  fi
  if [ "$sp_dir" = out ]; then
    echo low > "$SYSFS/gpio$sp_n/direction" 2>/dev/null || { sp_fail "cannot set output"; return; }
    log "pin $sp_id: linux gpio $sp_n -> output, LOW"
  else
    echo in > "$SYSFS/gpio$sp_n/direction" 2>/dev/null || { sp_fail "cannot set input"; return; }
    log "pin $sp_id: linux gpio $sp_n -> input"
  fi
  echo "gpio|$SYSFS/gpio$sp_n/value|$sp_n" > "$STATE/$sp_id.dat"
}

handle_pin() {  # id gpio dir wanted led
  id=$1; gpio=$2; dir=$3; want=$4; led=$5
  case "$id" in ''|*[!A-Za-z0-9_]*) return;; esac
  cfg="$gpio|$dir|$led"
  if [ "$(cat "$STATE/$id.cfg" 2>/dev/null)" != "$cfg" ]; then
    setup_pin "$id" "$gpio" "$dir" "$led"
    echo "$cfg" > "$STATE/$id.cfg"
  fi
  IFS='|' read -r mode vfile pn < "$STATE/$id.dat"
  if [ "$mode" = ERR ] || [ -z "$mode" ]; then REP="$REP,$id:E"; return; fi

  # Only ever write to a pin the config says is an output
  if [ "$dir" = out ]; then
    case "$want" in
      0|1)
        cur=$(read_val "$mode" "$vfile" "$pn")
        if [ "$cur" != "$want" ]; then
          echo "$want" > "$vfile" 2>/dev/null || log "pin $id: write failed"
          log "pin $id -> $want"
        fi;;
    esac
  fi
  REP="$REP,$id:$(read_val "$mode" "$vfile" "$pn")"
}

# ---------------------------------------------------------------- main
mkdir -p "$STATE" 2>/dev/null
rm -f "$STATE"/* 2>/dev/null          # fresh start => every output is set LOW again
log "gpio-agent starting (http tool: $HTTP)"
find_chip || { log "FATAL: no gpiochip found in $SYSFS"; exit 1; }
sync_time
last_sync=$(uptime_s)

first=1; fails=0; rfail=0
while :; do
  if ! year_ok; then
    now_up=$(uptime_s)
    if [ $((now_up - last_sync)) -ge 60 ]; then last_sync=$now_up; sync_time; fi
  fi

  q="$URL?action=poll&key=$KEY"
  [ "$first" = 1 ] && q="$q&boot=1"
  resp=$(fetch "$q" | tr -d '\r')
  head1=$(printf '%s\n' "$resp" | head -n 1)

  if [ "$head1" != "OK" ]; then
    fails=$((fails + 1))
    if [ "$fails" -eq 1 ] || [ $((fails % 30)) -eq 0 ]; then
      case "$head1" in
        ERR*) log "server said '$head1' (wrong KEY?)";;
        *)    log "poll failed ($fails in a row): no internet, HTTPS problem or wrong URL. Keeping last pin states.";;
      esac
    fi
    sleep "$INTERVAL"
    continue
  fi
  [ "$fails" -gt 0 ] && log "link restored after $fails failed polls"
  fails=0; first=0

  REP=""
  while IFS='|' read -r tag a b c d e; do
    case "$tag" in
      TIME) year_ok || set_clock "$a";;
      P)    handle_pin "$a" "$b" "$c" "$d" "$e";;
    esac
  done <<EOF
$resp
EOF

  if [ -n "$REP" ]; then
    r=$(fetch "$URL?action=report&key=$KEY&s=${REP#,}" | head -n 1 | tr -d '\r')
    if [ "$r" = "OK" ]; then
      [ "$rfail" = 1 ] && log "report OK again"
      rfail=0
    elif [ "$rfail" = 0 ]; then
      log "report failed ('$r')"; rfail=1
    fi
  fi
  sleep "$INTERVAL"
done
