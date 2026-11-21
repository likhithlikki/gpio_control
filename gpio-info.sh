#!/bin/sh
# gpio-info.sh - READ-ONLY board data collector for the "Board details" web page.
# Sends data only while that page is open. It never changes a pin's direction or value
# (it briefly exports each GPIO line to read it, then releases it).
CONF=${CONF:-/etc/gpio-agent.conf}
[ -r "$CONF" ] && . "$CONF"
G=/sys/class/gpio
get() { if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 20 "$1" 2>/dev/null; else wget -q -T 20 -O - "$1" 2>/dev/null; fi; }
put() { get "$URL?action=infoPut&part=$1&d=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._:,~/-' '_')&key=$KEY" >/dev/null; }
PB=0; PT=0
BASE=""; N=0
for c in $G/gpiochip*; do
  read -r lb < $c/label 2>/dev/null
  [ "$lb" = zynq_gpio ] && { read -r BASE < $c/base; read -r N < $c/ngpio; }
done

sysinfo() {
  read -r up _ < /proc/uptime
  read -r l1 l5 l15 _ < /proc/loadavg
  read -r _ u n s i w q sq _ < /proc/stat
  busy=$((u+n+s+q+sq)); tot=$((busy+i+w)); pct=0
  [ $((tot-PT)) -gt 0 ] && pct=$((100*(busy-PB)/(tot-PT)))
  PB=$busy; PT=$tot
  C=/sys/devices/system/cpu/cpu0/cpufreq; f=-; fm=-; fn=-; gov=-
  [ -r $C/scaling_cur_freq ] && read -r f < $C/scaling_cur_freq
  [ -r $C/cpuinfo_max_freq ] && read -r fm < $C/cpuinfo_max_freq
  [ -r $C/cpuinfo_min_freq ] && read -r fn < $C/cpuinfo_min_freq
  [ -r $C/scaling_governor ] && read -r gov < $C/scaling_governor
  mt=-; ma=-
  while read -r k v _; do case $k in MemTotal:) mt=$v;; MemAvailable:) ma=$v;; esac; done < /proc/meminfo
  dk=$(df -k 2>/dev/null | while read -r fs t u2 a p m; do case $fs in /dev/*) echo "${fs##*/}/$t/$u2";; esac; done | tr '\n' '~')
  nt=""
  for e in eth0 eth1 eth2; do
    N_=/sys/class/net/$e; [ -d $N_ ] || continue
    read -r st < $N_/operstate; sp=-; [ "$st" = up ] && read -r sp < $N_/speed 2>/dev/null
    read -r rx < $N_/statistics/rx_bytes; read -r tx < $N_/statistics/tx_bytes; read -r mac < $N_/address
    ip=$(ifconfig $e 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
    nt="$nt$e/$st/$sp/$rx/$tx/${ip:--}/$(echo $mac | tr : -)~"
  done
  fl=$(tail -n 100 /var/log/gpio-agent.log 2>/dev/null | grep -c 'poll failed')
  put sys "up:${up%.*},ld:${l1}_${l5}_${l15},cpu:$pct,f:$f,fm:$fm,fn:$fn,gov:$gov,mt:$mt,ma:$ma,k:$(uname -r),fl:$fl,d:${dk:--},n:${nt:--}"
}

clkinfo() {
  WANT=" armpll ddrpll iopll cpu_6or4x cpu_3or2x cpu_2x cpu_1x ddr2x ddr3x fclk0 fclk1 fclk2 fclk3 gem0 gem1 sdio0 sdio1 uart0 uart1 spi0 spi1 lqspi i2c0 i2c1 usb0 usb1 can0 can1 dbg_trc ps_clk "
  cl=""
  if [ -r /sys/kernel/debug/clk/clk_summary ]; then
    while read -r nm e p pr rate _; do case "$WANT" in *" $nm "*) cl="$cl$nm/$rate~";; esac; done < /sys/kernel/debug/clk/clk_summary
  fi
  X=""; I=/sys/bus/iio/devices/iio:device0
  for f in $I/in_*_raw; do
    [ -r "$f" ] || continue
    b=${f%_raw}; nm=${b##*/in_}; ty=${nm%%[0-9]*}; r=-; o=0; sc=1
    read -r r < $f 2>/dev/null
    if [ -r ${b}_offset ]; then read -r o < ${b}_offset; elif [ -r $I/in_${ty}_offset ]; then read -r o < $I/in_${ty}_offset; fi
    if [ -r ${b}_scale ]; then read -r sc < ${b}_scale; elif [ -r $I/in_${ty}_scale ]; then read -r sc < $I/in_${ty}_scale; fi
    X="$X$nm/$r/$o/$sc~"
  done
  put clk "c:${cl:--},x:${X:--}"
}

pininfo() {
  [ -n "$BASE" ] || return
  dirs=""; vals=""; n=0
  while [ $n -lt $N ]; do
    g=$((BASE+n)); ex=0; c=x; v=-
    if [ ! -d $G/gpio$g ]; then { echo $g > $G/export; } 2>/dev/null && ex=1; fi
    if [ -r $G/gpio$g/value ]; then
      read -r d < $G/gpio$g/direction; read -r v < $G/gpio$g/value
      case $d in in) c=i;; out) c=o;; esac
    fi
    [ $ex = 1 ] && echo $g > $G/unexport
    dirs="$dirs$c"; vals="$vals$v"; n=$((n+1))
  done
  ow=$(sed -n 's/^ *gpio-\([0-9]*\) ([^|]*|\([^ )]*\) *).*/\1:\2/p' /sys/kernel/debug/gpio 2>/dev/null | tr '\n' ',')
  put pin "b:$BASE,d:$dirs,v:$vals,o:${ow:--}"
}

while true; do
  if [ "$(get "$URL?action=infoPoll&key=$KEY")" = W ]; then sysinfo; clkinfo; pininfo; sleep 2; else sleep 8; fi
done
