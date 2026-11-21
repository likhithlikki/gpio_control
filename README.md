# GPIO Control — Internet GPIO Controller for the MYD-Y7Z020

Switch pins and LEDs on an embedded Linux board from any phone or PC browser, from anywhere,
with **no port forwarding, no static IP and no server of your own**.

---

## 1. What is it for?

The MYD-Y7Z020 board (Xilinx Zynq-7020, PetaLinux 2024.2) sits behind an ordinary router.
You cannot connect *to* it from the internet, so this project turns the problem around:
**the board connects out** to a free Google Apps Script web app and asks what to do.
Your browser talks to the same web app. Google is the meeting point in the middle.

What you get:

- A web page with one switch per pin (currently: System LED, User LED, User GPIO).
- Live status: *Board online/offline*, the value you asked for (**desired**), the value the
  board really measured (**actual**), and a state of *pending*, *confirmed* or *error*.
- A Google Sheet that records every change (History, State and Log tabs, times in IST).

## 2. How it works

```
 Phone / PC browser            Google Apps Script web app               Board (MYD-Y7Z020)
 ┌──────────────┐  switch     ┌─────────────────────────────┐   every ~2 s   ┌──────────────────┐
 │  index.html  │ ──────────► │ code.gs                     │ ◄───────────── │ gpio-agent.sh    │
 │  (the page)  │ ◄────────── │  stores desired pin values  │  1) poll:      │  sets the pins   │
 └──────────────┘  status     │  + last report from board   │  "what should  │  reads them back │
                              │  + Google Sheet log         │   my pins be?" │                  │
                              └─────────────────────────────┘  2) report:    └──────────────────┘
                                                               "they are ..."
```

One cycle on the board (about every 2 seconds, two HTTPS requests):

1. **Poll** — asks `?action=poll&key=…`. The backend answers with the desired value of every pin
   (and the current time, which the board uses to fix its clock).
2. **Drive** — writes each output pin through `/sys/class/gpio`.
3. **Read back** — reads the real pin value from the kernel.
4. **Report** — sends the real values with `?action=report&key=…`.

The page shows *confirmed* when actual equals desired. If the board has not reported for
10 seconds the page shows **Board offline**. If actual differs from desired for more than
10 seconds the pin shows **error / mismatch**.

Safety behaviours:

- Every request needs the secret key (`SECRET` in `code.gs` = `KEY` in `/etc/gpio-agent.conf`).
- When the agent starts, all outputs go **OFF** and the stored desired values are reset to OFF,
  so the page never shows ON while the board is really off.
- If the internet drops, the board keeps the last pin states and keeps retrying.
- Stopping the agent leaves the pins as they are.

## 3. Parts of the project

| File | Where it lives | Job |
|---|---|---|
| `code.gs` | Google Apps Script | Backend: API, stored state, the `PINS` list, Sheet logging |
| `index.html` | Apps Script / GitHub Pages | The control page |
| `gpio-agent.sh` | board `/usr/local/bin/` | The agent: poll, drive pins, read back, report, set clock |
| `gpio-net.sh` | board `/usr/local/bin/` | Retries DHCP every 10 s until `eth0` has an IP (the link comes up slowly after boot) |
| `gpio-agent` | board `/etc/init.d/` | Boot script: starts `gpio-net.sh` and the agent at startup |
| `gpio-agent.conf` | board `/etc/` | `URL` of the web app, `KEY`, `INTERVAL` (seconds) |
| `install.sh` | this folder | Copies everything to the right places and enables start at boot |
| `run.sh` | this folder | Runs the agent from this folder without installing |
| `check.sh` | this folder | Health check (section 6) |

Pins are defined **only** in `code.gs`:

```js
const PINS = [
  { id: 'sys_led',  name: 'System LED', gpio: 8,  dir: 'out', led: 'sys_led'  },  // MIO 8
  { id: 'usr_led',  name: 'User LED',   gpio: 54, dir: 'out', led: 'usr_led'  },  // EMIO 54
  { id: 'usr_gpio', name: 'User GPIO',  gpio: 55, dir: 'out', led: 'usr_gpio' },  // EMIO 55
];
```

`gpio` is the Zynq number (MIO 0–53, EMIO 54 and up). The agent adds the gpiochip base it finds
(512 on this board), so MIO 8 becomes Linux GPIO 520, EMIO 54 becomes 566 and EMIO 55 becomes 567.
To add a pin: add one line, save, then *Deploy → Manage deployments → New version*. The board needs no change.

## 4. Where the code is stored (does it survive power-off?)

The board boots the kernel from SPI flash and mounts its root filesystem from the on-board
**eMMC** (`/dev/mmcblk1p2`, ext4). The installed files live there, so they **survive power-off**.
Run `sync` before cutting power. The SD card (`mmcblk0`) is not used to boot; this folder on it
is a backup and installer. The SD card is FAT, so files on it are not executable and must be
started with `sh`. Leave the boot switches as they are.

## 5. Running it in the PuTTY terminal

### 5.1 Connect

- **Serial:** Device Manager → Ports shows `COMx`. In PuTTY choose *Serial*, line `COMx`, speed `115200`.
- **SSH:** on the board run `ifconfig eth0` to read the IP, then PuTTY → *SSH* → that IP, user `root`.

### 5.2 Find this folder on the SD card

```sh
mount | grep mmcblk0
ls /run/media/mmcblk0p1/gpio_control
```

The examples below assume `/run/media/mmcblk0p1`. Use the path your `mount` output shows.
Run commands **one line at a time**.

### 5.3 Run once (no install)

First make sure no other agent is running, then start it in the foreground:

```sh
/etc/init.d/gpio-agent stop
sh /run/media/mmcblk0p1/gpio_control/run.sh
```

You should see the gpiochip line (`base=512 ngpio=118`) and one line per pin. Open the web page:
**Board online** appears within a few seconds and switches move the LEDs. Press **Ctrl+C** to stop.

To run in the background and keep the terminal free (then use the check):

```sh
sh /run/media/mmcblk0p1/gpio_control/run.sh bg
sh /run/media/mmcblk0p1/gpio_control/check.sh
sh /run/media/mmcblk0p1/gpio_control/run.sh stop
```

### 5.4 Install permanently (starts at every boot)

```sh
sh /run/media/mmcblk0p1/gpio_control/install.sh
```

Useful commands afterwards:

```sh
/etc/init.d/gpio-agent status
/etc/init.d/gpio-agent stop
/etc/init.d/gpio-agent start
tail -n 20 /var/log/gpio-agent.log
```

## 6. Checking that everything works

```sh
sh /run/media/mmcblk0p1/gpio_control/check.sh
```

It prints `[ OK ]`, `[WARN]` or `[FAIL]` for each of these and ends with a pass/fail count:

1. Config has `URL` and `KEY`
2. Clock is valid (year 2025 or later)
3. `eth0` has an IP, the internet is reachable, and DNS resolves `script.google.com`
4. The Google backend answers and accepts the key
5. The backend reports the board **online**
6. A gpiochip exists and the agent process is running
7. The agent is installed for boot
8. The last log lines (a failed last poll is flagged), and each pin's desired, actual and state

For a full end-to-end test add `--toggle`. It flips the first pin through the backend, waits for the
board to confirm it, then restores it:

```sh
sh /run/media/mmcblk0p1/gpio_control/check.sh --toggle
```

## 7. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `eth0` has no IP after boot | DHCP gave up before the link was up. `gpio-net.sh` retries every 10 s; or run `udhcpc -i eth0` |
| Log: `poll failed` | No internet or DNS, wrong URL, or `code.gs` changed but not redeployed as a *New version* |
| Log: `server said 'ERR\|badkey'` | `KEY` in `/etc/gpio-agent.conf` differs from `SECRET` in `code.gs` |
| Page says *Wrong key* | The key typed on the page differs from `SECRET` |
| Page *Board offline* but agent running | Network problem; run `check.sh` and read the first FAIL |
| `not found` or `bad interpreter` | Windows line endings: `sed -i 's/\r$//' file` |
| Pin shows *mismatch* | Board reports a value different from desired for more than 10 s; read the log |
| `cannot export linux gpio` | A kernel driver owns the pin; use the `led:` name from `ls /sys/class/leds` |
| Clock shows 2018 | No battery RTC. The agent sets the clock once it is online |

## 8. Security and limits

- Anyone who has the web app URL **and** the key can switch your pins. Use a long random key
  (24+ letters and digits), not `12345`.
  To change it: edit `SECRET` in `code.gs`, redeploy as a new version, then update `KEY` in `/etc/gpio-agent.conf`.
- Do not put `gpio-agent.conf` (URL and key) in a public GitHub repo.
- BusyBox `wget` on this image does not validate TLS certificates, so use a private network you trust.
- About one request per second to Google. If Google throttles you, raise `INTERVAL` in the config.
- Do not use this to switch anything safety-critical. It depends on the internet and on Google.
- GPIO uses the legacy sysfs interface. If a future kernel removes it, the log shows `no gpiochip found`
  and the agent needs a libgpiod version.

## 9. Updating the code on the board

Edit the files in this folder (or on your PC), copy the folder to the SD card, then:

```sh
sh /run/media/mmcblk0p1/gpio_control/install.sh
```

`install.sh` keeps your existing `/etc/gpio-agent.conf`. Add `--conf` to overwrite it with the one in this folder.
