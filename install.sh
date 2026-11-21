#!/bin/sh
# Installs the GPIO agent onto the board's eMMC so it starts at every boot.
# Usage (from anywhere):  sh /path/to/gpio_control/install.sh
# Add  --conf  to also overwrite /etc/gpio-agent.conf with the one in this folder.
D=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
for f in gpio-agent.sh gpio-net.sh gpio-info.sh gpio-agent; do
  [ -f "$D/$f" ] || { echo "Missing $D/$f"; exit 1; }
done
mkdir -p /usr/local/bin /etc/rc5.d
cp "$D/gpio-agent.sh" /usr/local/bin/gpio-agent.sh
cp "$D/gpio-net.sh"   /usr/local/bin/gpio-net.sh
cp "$D/gpio-info.sh"  /usr/local/bin/gpio-info.sh
cp "$D/gpio-agent"    /etc/init.d/gpio-agent
sed -i 's/\r$//' /usr/local/bin/gpio-agent.sh /usr/local/bin/gpio-net.sh /usr/local/bin/gpio-info.sh /etc/init.d/gpio-agent
chmod +x /usr/local/bin/gpio-agent.sh /usr/local/bin/gpio-net.sh /usr/local/bin/gpio-info.sh /etc/init.d/gpio-agent
if [ ! -f /etc/gpio-agent.conf ] || [ "$1" = "--conf" ]; then
  cp "$D/gpio-agent.conf" /etc/gpio-agent.conf
  sed -i 's/\r$//' /etc/gpio-agent.conf
  echo "Config copied to /etc/gpio-agent.conf"
else
  echo "Kept existing /etc/gpio-agent.conf"
fi
ln -sf /etc/init.d/gpio-agent /etc/rc5.d/S99gpio-agent
/etc/init.d/gpio-agent restart
sync
echo "Waiting for an IP address on eth0 (up to 40 s)..."
i=0
while [ $i -lt 20 ]; do
  ifconfig eth0 2>/dev/null | grep -q 'inet addr:' && break
  sleep 2; i=$((i+1))
done
ifconfig eth0 | grep 'inet addr' || echo "No IP yet - check the network cable (eth0)."
echo "Installed. Check the web page for 'Board online'. Log: /var/log/gpio-agent.log"
