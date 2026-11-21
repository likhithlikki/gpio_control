#!/bin/sh
# gpio-net.sh - keeps eth0 supplied with an IPv4 address (retries DHCP forever).
# Needed because the PHY link comes up slower than udhcpc's boot-time attempt.
IF=eth0
while true; do
  if ! ifconfig "$IF" 2>/dev/null | grep -q 'inet addr:'; then
    ifconfig "$IF" up 2>/dev/null
    killall udhcpc 2>/dev/null
    udhcpc -i "$IF" -n -t 4 -T 3 >/dev/null 2>&1
  fi
  sleep 10
done
