# neato-FHEM

*[English](#english) | [Deutsch](#deutsch)*

Neato-Botvac-Saugroboter lokal aus FHEM steuern – ohne Cloud, über die
serielle Konsole, die in jedem Botvac steckt.

<a id="english"></a>

## English

The Neato cloud was switched off in the fourth quarter of 2025. That took the
app and every cloud-based integration with it, including the previous FHEM
module `74_BOTVAC.pm`. The robot itself is fine: navigation, SLAM, cleaning
and docking all run in its own firmware. The only thing missing is the
trigger that used to come from the cloud.

`74_NeatoLocal.pm` replaces that trigger. It talks to the serial console
built into every Botvac and turns it into an FHEM device with `set`, `get`
and readings – over USB, or through a small Wi-Fi bridge inside the robot.

### What you need

- **a Botvac with a serial console:**

  | Model | Status |
  |---|---|
  | Botvac Connected, D3, D4, D5, D6, D7 | supported, internal debug port or USB |
  | Botvac 65/70e/75/80/85, D75/D80/D85, XV | supported, board-edge connector P7/P25 or USB |
  | Botvac D8, D9, D10 | **not** supported: different board, the serial port is password-protected |

  Developed and tested on a **BotVac D6 Connected with software 4.5.3.189**.
  Other models are expected to work but have not been tested yet. Its full
  console transcript is in
  [`docs/reference-dump-botvac-d6.txt`](docs/reference-dump-botvac-d6.txt)
  and is what the tests run against.

- **a way to reach the console** – three transports, all handled by the same
  module:

  | Transport | In `define` | Use |
  |---|---|---|
  | serial | `/dev/ttyACM0@115200` | the robot's USB port, good for exploring |
  | TCP | `192.168.1.42:23` | Wi-Fi bridge inside the robot |
  | HTTP | `http://neato.local` | [OpenNeato](https://github.com/renjfk/OpenNeato) on an ESP32-C3 (untested) |

  For TCP, [`firmware/`](firmware/) contains a matching bridge: a sketch for
  an ESP32-C3 that sits inside the robot and puts its console on the network.
  The module can flash it itself (see
  [Setting up the bridge from FHEM](#setting-up-the-bridge-from-fhem)).
  Wiring and power are described in [docs/hardware.md](docs/hardware.md)
  (German).

  **About USB:** some firmware refuses to clean while a USB host is plugged
  in (error 220). For everyday use the internal debug port is the intended
  connection; USB is for exploring and diagnosis.

- **FHEM**, running on the machine the robot or the bridge is reachable from.

### Installation

#### Through FHEM update

```
update add https://raw.githubusercontent.com/chrisse1/neato-FHEM/main/controls_neatolocal.txt
update
shutdown restart
```

After that, a plain `update` keeps the module current; `update check` shows
beforehand what would change, and `update delete <url>` removes the source
again. FHEM writes straight into `/opt/fhem/FHEM/`, so the user FHEM runs as
needs write access there.

#### By hand

From a checkout of this repository:

```sh
sudo cp FHEM/74_NeatoLocal.pm /opt/fhem/FHEM/
sudo mkdir -p /opt/fhem/FHEM/lib
sudo cp FHEM/lib/NeatoLocalPlan.pm /opt/fhem/FHEM/lib/
sudo chown fhem:dialout /opt/fhem/FHEM/74_NeatoLocal.pm /opt/fhem/FHEM/lib/NeatoLocalPlan.pm
sudo chmod 644 /opt/fhem/FHEM/74_NeatoLocal.pm /opt/fhem/FHEM/lib/NeatoLocalPlan.pm
```

Then, on the FHEM command line:

```
reload 74_NeatoLocal.pm
define Staubsauger NeatoLocal 192.168.1.42:23
attr Staubsauger interval 60
save
```

The address may be left out: `define Staubsauger NeatoLocal` creates the
device without connecting, for when the bridge still has to be flashed.

`reload` is not optional: FHEM reads its `FHEM/` directory at startup and
does not know about a file added later – `define` would fail with *Cannot
load module NeatoLocal*. Restarting FHEM does the same. Without `save`, the
definition is gone after the next restart.

#### Serial port permissions

Only needed for the serial transport, not for the Wi-Fi bridge. The file
permissions of the module have nothing to do with access to `/dev/ttyACM0`:
the port usually belongs to `root:dialout`, so the user FHEM runs as has to
be in that group.

```sh
id fhem                          # is dialout listed?
sudo usermod -aG dialout fhem    # if not
sudo systemctl restart fhem      # group changes only apply after a restart
```

Only one process can have the port open at a time – a running
`dump_robot.py` blocks FHEM and vice versa.

### What the module can do

#### Cleaning and settings

| Command | Effect |
|---|---|
| `startCleaning [house\|spot\|explore\|persistent]` | house cleaning (default), spot cleaning; `explore` and `persistent` see [below](#explore-and-persistent-need-the-app) |
| `stop` | end cleaning |
| `pause` / `resume` | pause and resume cleaning |
| `sendToBase` | return to the base |
| `findMe` | play a sound to find the robot |
| `clearError` | acknowledge the reported error or alert |
| `navigationMode Normal\|Gentle\|Deep\|Quick` | cleaning mode |
| `ecoMode on\|off` | quieter, less suction |
| `intenseClean on\|off` | intense cleaning |
| `binFullDetect on\|off` | full dust bin detection |
| `syncTime` | set the robot's clock from FHEM |
| `button <name>` | simulate any button press |
| `flashESP [<image>] [<ssid> <password>]` | write the bridge firmware to a board on a USB port |
| `wifiESP <ssid> <password>` | give a flashed board new Wi-Fi credentials over USB |
| `otaESP [<ip>] [<image>] [force]` | update the installed bridge over Wi-Fi |
| `buildPlan` | compute a shared floor plan from the latest recordings |
| `statusRequest` | poll the robot now |
| `reconnect` | rebuild the connection |
| `testMode on\|off` | the console's diagnostic mode, see below |
| `raw <command>` | send any console command |

**`testMode`** puts the robot into diagnostic mode, where it neither reacts
to its buttons nor cleans. The module never enables it on its own and always
sends `TestMode Off` on shutdown, delete and `disable`.

#### Queries

| Query | Content |
|---|---|
| `help [command]` | the robot's command list, or help for one command |
| `version` | model, serial number, firmware |
| `state` | state as reported by the robot |
| `charger` | battery and charging values |
| `battery` | readings from the smart battery |
| `warranty` | lifetime counters |
| `settings` | user settings |
| `accel` | the robot's tilt: readings `pitch`, `roll`, `accelSum` |
| `motors`, `sensors`, `usage`, `wifiStatus` | raw data |
| `serialPorts` | the host's serial ports with their by-id names |
| `raw <command>` | any console command |

#### State

`state` is one of `cleaning`, `paused`, `suspended`, `docking`, `charging`,
`docked`, `idle`, `error`, `robotSilent`, `unreachable` and `disconnected`.

* **`suspended`** – the robot interrupted the cleaning itself, almost always
  because of a low battery, and wants to continue after charging. If
  `isDocked` is `0` at the same time, it did not make it back to the base.
* **`robotSilent`** – the connection to the bridge is up, but the robot does
  not answer: it is asleep, or the bridge is not wired to it yet. Right after
  flashing this is the normal state and says nothing bad about the bridge.
* **`unreachable`** – the connection itself is gone: the bridge is not on the
  network or has no power.

In both cases polling backs off step by step up to 16 times the interval, at
most one hour, instead of filling the log with timeouts. The first answer
resets everything.

`uiState` and `robotState` pass on the state exactly as the robot reports it.

#### Battery

| Reading | Meaning |
|---|---|
| `batteryPercent` | charge level in percent |
| `batteryHealth` | remaining capacity as a percentage of the design capacity |
| `batteryCapacityFull`, `batteryCapacityDesign` | current and original capacity in mAh |
| `batteryCycles`, `cleaningHours` | lifetime counters |
| `batteryVoltage`, `batteryTemperature`, `batteryState` | voltage, temperature, ok/low |
| `isCharging`, `isDocked` | charging and docking state |

`batteryHealth` comes from the measuring electronics inside the battery and
reliably predicts when a robot will get stranded. Below about 50 % it
increasingly fails to make it back to the base, even though the charge
display looks fine until shortly before:

```
define di_battery DOIF ([Staubsauger:batteryHealth] < 50) (set Message battery weak)
```

#### Errors and alerts

`error`/`errorCode` and `alert`/`alertCode` are kept apart: a full dust bin
(alert 248) is not an error and does not put the device into the error
state, a missing bin (error 249) does. Code 200 (`UI_ALERT_INVALID`) means
"nothing to report".

#### Settings and device information

`ecoMode`, `intenseClean`, `binFullDetect`, `wallFollower`, `clickSounds`,
`melodySounds`, `warningSounds`, `led`, `wifiEnabled`, `language`,
`filterChangeTime`, `brushChangeTime`, `dirtBinInterval`, `scheduleEnabled`,
`scheduledCleanings` – read on connect and after every change.

`model`, `serialNumber`, `firmware`, `ldsSoftware`, `hardware`, `commandApi`.

`navigationMode` is the exception: the console has no command to read it.
The reading therefore holds the value last set. Because the robot does not
keep the mode across runs, the module sends it again before every house
cleaning.

The reading names deliberately follow those of `74_BOTVAC.pm`, so existing
`notify` and `DOIF` definitions keep working with small adjustments.

#### Attributes

| Attribute | Default | Meaning |
|---|---|---|
| `interval` | 60 | polling interval in seconds |
| `timeout` | 10 | how long to wait for an answer |
| `connectTimeout` | 2 | upper limit for one connection attempt |
| `espPort` | `/dev/ttyACM0` | USB port of the bridge board when flashing |
| `espImage` | – | image `flashESP` writes when none is given |
| `espAppImage` | – | application `otaESP` sends when none is given |
| `pollState` | 1 | also poll `GetState` |
| `pollErrors` | 1 | also poll `GetErr` |
| `pollMotors` | 0 | also poll `GetMotors` |
| `pollSettings` | 0 | read the user settings on every poll |
| `useSetEvent` | 1 | use the event interface when available |
| `cmdCleanHouse`, `cmdCleanSpot`, `cmdCleanExplore`, `cmdCleanPersistent`, `cmdCleanStop`, `cmdCleanPause`, `cmdCleanResume`, `cmdSendToBase`, `cmdFindMe` | – | override the console command behind a set command |
| `httpPath`, `httpMethod` | `/api/serial`, POST | HTTP transport only |
| `disable` | 0 | close the connection and stop polling |
| `disabledForIntervals` | – | time windows in which the device rests (FHEM standard attribute) |

The attributes for recording and the map are described with their sections:
`trackRuns`, `trackDir`, `trackInterval`, `trackPose`, `trackKeepDays`,
`mapInterval` and `mapMaxRange` under
[Recording runs](#recording-runs), `planAuto`, `planSources` and `planCell`
under [A floor plan from several runs](#a-floor-plan-from-several-runs).

#### Setting up the bridge from FHEM

A brand-new ESP32-C3 can be put into service from the FHEM host, without an
Arduino installation and without the credentials ending up in the firmware.
It needs `esptool` (`pip3 install esptool` or your distribution's package)
and the board on a USB port.

**Finding the right port.** An ESP32-C3 **and** the robot both show up as
`/dev/ttyACM*`, so the number alone says nothing about what is behind it.
The module answers that itself, even without a configured bridge:

```
get Staubsauger serialPorts
```

```
/dev/ttyACM0     ESP32 (native USB)
                 /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_9C-if00
/dev/ttyACM1     Neato robot
                 /dev/serial/by-id/usb-Neato_Robotics_Botvac_D6-if00
```

The **by-id name** is the better choice for `espPort` or a `define`: it stays
the same across restarts and does not depend on which USB socket the device
is in. If no port shows up at all, it is usually a charge-only cable without
data lines.

**From a bare board to a running device:**

```
define Staubsauger NeatoLocal
attr Staubsauger espPort /dev/ttyACM0
set Staubsauger flashESP "My WLAN" "long passphrase"
save
```

The `define` **without an address** is the key: `flashESP` needs a device,
but the bridge has no address yet at that point. The device sits in state
`unconfigured`, does not connect and does not poll. `flashESP` fetches the
image this project's CI builds, writes it, stores the credentials on the
board, and finally asks the board over the same USB port which address it
got. That address goes into the reading `bridgeAddress`, and a device
defined without an address points itself at it and connects. `save` keeps
it. A device that already has an address keeps it; the log only notes where
the new bridge can be reached.

Quote SSID and password if they contain spaces. A semicolon has to be
written as `;;`, because FHEM splits commands on it. Flashing runs in its
own process, so FHEM stays responsive; the result is in the reading
`lastFlash`.

The ready-made image is in [`firmware/prebuilt/`](firmware/prebuilt/), built
by CI from source; the text file next to it names version, commit and
SHA-256. **FHEM `update` does not fetch the image** – `flashESP` downloads it
when needed. An image of your own takes precedence:
`set Staubsauger flashESP /path/to/image.bin`, or permanently through the
attribute `espImage`.

`wifiESP` is for when the Wi-Fi changes later: it hands the credentials to
the firmware's configuration console over USB and reports the new address in
`bridgeAddress`. If the board ends up in its access point instead, `lastFlash`
says why (password rejected, network not found, turned away by the router).

**Updating the installed bridge.** Once it is built in, the bridge is
powered by the robot's 3.3 V rail and no longer hangs on the server's USB
port. From then on updates go over Wi-Fi:

```
set Staubsauger otaESP
```

`otaESP` fetches the published application and pushes it to the bridge with
the ArduinoOTA protocol. The address comes from the device; a different one
can be given: `set Staubsauger otaESP 192.168.1.150`.

**One exception, and it matters:** firmware **before 0.4.0** had SSID and
password compiled *into the image*. An update replaces that image – and with
it the only copy of the credentials. The bridge then comes up without a
network and opens the access point `neato-setup`, where the credentials can
be entered at **http://192.168.4.1/** from a phone. No cable needed, but
someone has to be next to the robot. `otaESP` reads the running version and
**refuses** such an update until you say `set <dev> otaESP force`. From
0.4.0 on, the credentials live in flash and survive every update.

Not flashing from the FHEM host? A board without stored credentials opens
the access point `neato-setup` with an input page, and the firmware takes
the same commands over a terminal on the USB port (`help` lists them).
Flashing by hand with the Arduino IDE is described in
[docs/flashing-esp32c3.md](docs/flashing-esp32c3.md) (German). Why the
bridge's Wi-Fi behaves the way it does is in
[docs/hintergrund.md](docs/hintergrund.md) (German).

#### Recording runs

The robot keeps no log of its own and does not hand out its map over the
console. What can be reconstructed is the **path it drove**: during a run
the module polls `GetRobotPos` every `trackInterval` seconds and writes each
position as one JSON line. OpenNeato's "Cleaning History" is built the same
way, by recording rather than fetching.

Recording starts and ends with the run, even if it was started on the robot
itself or by its schedule. A session is stored as
`<trackDir>/<device>-<timestamp>.jsonl`:

```json
{"device":"Staubsauger","started":"2026-09-19_15-04-05","module":"0.16.0","unit":"m"}
{"t":1281.84,"x":0.000,"y":0.000,"th":0.0}
{"t":1284.91,"x":0.412,"y":0.003,"th":1.2}
{"summary":{"points":812,"distance":41.2,"rotation":3600,"seconds":2431}}
```

Coordinates in metres, `th` in degrees. The summary also goes into the
readings `trackPoints`, `trackDistance` and `trackDuration`, the file name
into `trackFile`.

**It is off by default**, because it creates one file per run, which is of
no use to anyone who does not display it:

```
attr Staubsauger trackRuns 1
```

The default directory is `./www/neato`, i.e. `/opt/fhem/www/neato`. Finished
sessions are removed after `trackKeepDays` days, 14 by default; `0` keeps
everything. Deleting is tightly limited: only inside `trackDir`, only names
matching `<device>-<timestamp>.jsonl`, only older than the limit, and never
the session being written. Your own files and other devices' sessions stay
untouched.

`trackPose` picks the position the path is built from: `Smooth` (default,
the position corrected by the robot) or `Raw`, the wheel encoders alone,
which drift over a run. Measured, that is the difference between 0.156 and
0.268 occupied cells per point; `Raw` is only there for comparison.

**Lidar scans.** The lidar spins on its own **during a run** – measured on a
D6 at about 5 revolutions per second with real distances. When idle it
stands still, and it could only be started with a TestMode command, in which
the robot does not clean. `mapInterval` (default 0 = off) fetches a
`GetLDSScan` every *n* seconds and stores it next to the path:

```json
{"scan":{"x":1.204,"y":0.418,"th":92.0,"speed":5.02,"pts":[[0,1284],[1,1266]]}}
```

Angle in degrees, distance in millimetres, both relative to the pose on the
same line. Readings with an error code are dropped, and so is anything
beyond `mapMaxRange` (default 6000 mm): a real scan returned rows **without**
an error code at about 16.8 m where nothing reflected, while a Botvac's lidar
reaches about five metres.

How the points are placed in the room (the formula is measured, not assumed)
and how a floor plan is made from them is described in
[docs/ftui3-map.md](docs/ftui3-map.md) (German). FHEM itself draws nothing;
the map component for FTUI3 is
[fhem-ftui-components-neatomaps](https://github.com/chrisse1/fhem-ftui-components-neatomaps).
For a quick look without FHEM, `tools/render_track.py` draws a session as
SVG:

```sh
python3 tools/render_track.py /opt/fhem/www/neato/Staubsauger-2026-09-20_11-59-11.jsonl
```

#### A floor plan from several runs

A single run is the map of *that run*, not of the flat: its own origin, its
own north, and only the rooms the robot got into that day. Laid on top of
each other, several runs can do two things none can alone – fill in missing
walls and let every cell be voted on. What three out of four runs call a
wall is a wall; what one calls a wall while the others looked at the same
spot and found floor was the drying rack.

```
attr Staubsauger planAuto 1
set Staubsauger buildPlan
```

The result is a JSON file next to the recordings, `plan-<device>.json`, named
in the reading `planFile`. The FTUI component `<ftui-neato-map view="plan">`
loads and draws it; file format and procedure are in `docs/plan-format.md`
of the
[component repository](https://github.com/chrisse1/fhem-ftui-components-neatomaps).

| Attribute | Default | Meaning |
|---|---|---|
| `planAuto` | 0 | recompute after every cleaning |
| `planSources` | 8 | how many recordings are used, newest first |
| `planCell` | 0.10 | cell size in metres; stored in the file, the display follows it |

**It takes a while.** Every run is rotated and shifted against the frame
until it fits, across *all* rotations – measured at roughly one minute per
recording on an ordinary PC, longer on a small board. It runs in a separate,
lower-priority process; FHEM itself does not stall. For a shorter run, use
fewer `planSources`.

Runs that do not fit are **rejected** rather than forced in – pressing a
different floor into the same frame draws walls straight through rooms.

```
planState   ok
            ok, 1 did not fit (0.33)
            ok, 2 did not fit (0.41, 0.33)
            failed: <reason>
```

The number in brackets is the score reached. **This reading is worth
logging:** the threshold below which a run is rejected (0.45) is an
assumption, not a measurement, and the evidence is still contradictory –
three real runs of the same flat scored 0.64 to 1.0, but a partial run
against a full one scored 0.33. Over a few weeks, `planState` is the series
that settles it. The same numbers are in the field `scores` of the plan file.

The same can be done by hand, without FHEM:

```sh
perl tools/neato_plan.pl /opt/fhem/www/neato Staubsauger
```

**Stray points.** Now and then a point lies behind a wall. The obvious
suspect is the robot tilting at tight spots, so since 0.22.0 every scan also
records the tilt (`"tilt":[pitch, roll, |a|]`, and `get <dev> accel` by
hand). Measured over a full run, the tilt does **not** explain the stray
points (correlation +0.05); they are single weak returns at long range, and
the occupancy grid already filters them out. There is therefore deliberately
no tilt filter. `tools/stray_points.py` repeats the analysis on any session;
the full measurement is in [docs/ftui3-map.md](docs/ftui3-map.md) (German).

#### Explore and persistent need the app

The robot's own help describes `startCleaning explore` and
`startCleaning persistent` as the equivalent of starting from the Smart App –
unlike `house` and `spot`. Observed on a D6 without cloud: the command is
accepted, the robot raises alert 236 `UI_ALERT_ACQUIRING_PERSISTENT_MAP_IDS`
and does not move.

**Worse:** afterwards it accepts further cleaning commands without doing
anything. Even `startCleaning house` goes nowhere until the robot is
**switched off and on again**. An explore attempt costs not only itself but
the next run as well.

Both modes are therefore refused unless `force` is appended:

```
set Staubsauger startCleaning explore force
```

The console has no command to create, assign or query persistent map IDs,
so it is likely those IDs came from the cloud – that is an inference from
the observed behaviour, not proven. `house` and `spot` work normally.

#### How commands reach the robot

The robot's `Help` output is incomplete. Pause, resume and return to base go
through `SetEvent`, the authenticated event interface the cloud used to
control the robot, which appears in no command list. Its key is computed
from the MAC address that `GetVersion` reports.

| set command | Route |
|---|---|
| `startCleaning`, `stop` | `SetEvent`, otherwise `Clean House` / `Clean Stop` |
| `pause` / `resume` | `SetEvent`, without a key `SetButton start` as a toggle |
| `sendToBase` | **only** `SetEvent` – the documented commands offer nothing for it |
| `findMe` | `PlaySound SoundID 20` |

The reading `commandApi` shows whether the interface is unlocked (`setEvent`
or `legacy`). `attr <dev> useSetEvent 0` forces the documented commands.

The event interface, `GetState` and the other undocumented commands were
found and decoded by the [OpenNeato](https://github.com/renjfk/OpenNeato)
project (MIT, © 2026 Soner Köksal). This module contains an independent Perl
implementation, checked against their C++ original on known values. All the
details are in [docs/serial-commands.md](docs/serial-commands.md) (German).

#### What does not work

* **No-go lines and zone cleaning.** The D6 had them in the app, but they
  came through its cloud – `GetVersion` names it in plain text,
  `nucleo.neatocloud.com` – and that is switched off. None of the 44
  commands in the console's help has anything to do with maps. What is
  known, what is unproven and which routes remain is in
  [docs/serial-commands.md](docs/serial-commands.md#no-go-linien-was-bekannt-ist-und-was-nicht)
  (German). The one solution that works today is Neato's magnetic boundary
  strip.
* **Robot firmware updates.** They only ever came through the cloud.
* **Reading the robot's own map.** The console has no command for it.

### Tools

#### Reading a robot's console

`tools/dump_robot.py` asks the robot for its command list, fetches the help
text for every command it names and adds the output of the harmless `Get*`
commands. The result documents what that particular firmware understands.

```
python3 tools/dump_robot.py --device /dev/ttyACM0
python3 tools/dump_robot.py --tcp 192.168.1.42:23
python3 tools/dump_robot.py --device /dev/ttyACM0 --diagnose
```

The script only reads: it sends nothing but `Help` and `Get*`. No
`TestMode`, no motor commands, no settings changes. Serial numbers are
masked so a dump can be shared safely (`--no-redact` turns that off). It
needs only a plain Python 3; pyserial is not required.

**If you own a model other than the D6, a dump from it is the most useful
thing you can contribute.** Everything the module knows about the console
comes from one robot.

`--diagnose` checks the device, permissions and processes holding it,
reports the USB ID, listens passively for five seconds and tries all three
line endings, each with a hex dump. The most common causes of a silent
console, in this order: a sleeping robot, the wrong port, a port in use,
and a charge-only cable.

#### Trying it without a robot

`tools/neato_sim.py` emulates a Botvac console over TCP, with command echo,
the `Ctrl-Z` terminator, the CSV output of the real device and plausible
behaviour: the battery drains while cleaning and charges on the base.

```
python3 tools/neato_sim.py
```

```
define Staubsauger NeatoLocal 127.0.0.1:8888
```

With `--usb` the simulator refuses to clean with error 220, like a robot
with a USB host plugged in.

### The test suite

```
perl tools/check_module.pl        # module: loading, transports, parsers, state logic
perl tools/check_ota.pl           # update over Wi-Fi, against a stand-in for the bridge
python3 tools/check_sim.py        # simulator: protocol and state transitions
python3 tools/check_dump.py       # dump tool, serial over a PTY and over TCP
python3 tools/check_track.py      # session format and coordinate convention
python3 tools/check_partition.py  # partition table of the image
perl tools/check_plan.pl          # floor plan against the reference case (takes a minute)
perl tools/check_plan.pl --quick  # only the fast checks of the above
```

`check_plan.pl` rebuilds the reference case from `docs/reference-plan/` and
compares the result with what the JavaScript reference makes of the same
three recordings. It does not demand cell-for-cell equality; the bounds are
in `docs/plan-format.md` of the component repository.

All of them run without an FHEM installation and without a robot. The test
data are verbatim console outputs of a BotVac D6. CI runs them on every push
and also builds the bridge firmware for the ESP32-C3.

### When something is stuck

**FHEM freezes briefly.** FHEM opens TCP connections synchronously; while an
attempt is running, the whole process waits. The bridge is powered by the
robot and disappears when the robot is off. The module limits an attempt to
2 seconds, `connectTimeout` lowers that further. `apptime` on the FHEM
command line shows it: `NeatoLocal_Ready` or `DevIo_OpenDev` with a long
runtime means it is the connection setup.

**The robot does not answer.** `state` is `robotSilent`: wake the robot,
check the bridge's wiring (`http://neato.local/` shows the byte counters in
both directions), or run `--diagnose` on the USB port.

**The bridge is gone.** `state` is `unreachable`: the connection does not
come up. Check power and Wi-Fi, not the wiring to the robot.

**A command has no effect.** `get <dev> help Clean` shows what the firmware
understands; the `cmd*` attributes let you adjust any command.

### Background

Why some things are built the way they are – the bridge's Wi-Fi, flashing,
updates – is written down separately in
[docs/hintergrund.md](docs/hintergrund.md) (German). The console commands are
in [docs/serial-commands.md](docs/serial-commands.md), the map in
[docs/ftui3-map.md](docs/ftui3-map.md), and the hardware in
[docs/hardware.md](docs/hardware.md).

### License

GPLv2, like FHEM itself – the full text is in [LICENSE](LICENSE).

The SKey computation for the `SetEvent` commands is an independent
reimplementation of what [OpenNeato](https://github.com/renjfk/OpenNeato)
(MIT, © 2026 Soner Köksal) reverse-engineered, checked against its C++
original on known values.

<a id="deutsch"></a>

## Deutsch

Die Neato-Cloud wurde im 4. Quartal 2025 abgeschaltet. Damit sind die App und
alle cloudbasierten Anbindungen tot, darunter das bisherige FHEM-Modul
`74_BOTVAC.pm`. Der Roboter selbst ist es nicht: Navigation, SLAM, Reinigung
und Andocken laufen vollständig in seiner Firmware. Es fehlt nur der Auslöser,
der bisher aus der Cloud kam.

`74_NeatoLocal.pm` ersetzt diesen Auslöser. Es spricht die serielle Konsole an,
die in jedem Botvac steckt, und macht daraus ein FHEM-Gerät mit `set`, `get`
und Readings – über USB oder über eine kleine WLAN-Brücke im Roboter.

### Was man braucht

- **einen Botvac mit serieller Konsole:**

  | Modell | Status |
  |---|---|
  | Botvac Connected, D3, D4, D5, D6, D7 | unterstützt, interner Debug-Port oder USB |
  | Botvac 65/70e/75/80/85, D75/D80/D85, XV | unterstützt, Kartenrand-Stecker P7/P25 oder USB |
  | Botvac D8, D9, D10 | **nicht** unterstützt: anderes Board, serieller Port ist passwortgeschützt |

  Entwickelt und geprüft an einem **BotVac D6 Connected mit Software
  4.5.3.189**. Die anderen Modelle sollten funktionieren, sind aber noch
  nicht geprüft. Der vollständige Mitschnitt seiner Konsole liegt in
  [`docs/reference-dump-botvac-d6.txt`](docs/reference-dump-botvac-d6.txt)
  und dient den Tests als Grundlage.

- **einen Weg zur Konsole** – drei Transportwege, alle vom selben Modul
  bedient:

  | Transport | Angabe im `define` | Einsatz |
  |---|---|---|
  | seriell | `/dev/ttyACM0@115200` | USB-Port des Roboters, gut zum Erkunden |
  | TCP | `192.168.1.42:23` | WLAN-Brücke im Roboter |
  | HTTP | `http://neato.local` | [OpenNeato](https://github.com/renjfk/OpenNeato) auf einem ESP32-C3 (ungetestet) |

  Für TCP liegt in [`firmware/`](firmware/) eine passende Brücke: ein Sketch
  für einen ESP32-C3, der im Roboter sitzt und dessen Konsole ins Netz
  bringt. Das Modul kann sie selbst flashen (siehe
  [Brücke aus FHEM heraus einrichten](#brücke-aus-fhem-heraus-einrichten)).
  Verdrahtung und Stromversorgung stehen in
  [docs/hardware.md](docs/hardware.md).

  **Hinweis zu USB:** Manche Firmware verweigert die Reinigung, solange ein
  USB-Host angesteckt ist (Fehler 220). Für den Dauerbetrieb ist der interne
  Debug-Port vorgesehen; USB eignet sich zum Erkunden und für die Diagnose.

- **FHEM**, auf dem Rechner, von dem aus Roboter oder Brücke erreichbar sind.

### Installation

#### Über den FHEM-Updatemechanismus

```
update add https://raw.githubusercontent.com/chrisse1/neato-FHEM/main/controls_neatolocal.txt
update
shutdown restart
```

Danach genügt ein `update`, um auf den neuesten Stand zu kommen; `update check`
zeigt vorher, was sich ändern würde, `update delete <url>` entfernt die Quelle
wieder. FHEM schreibt dabei direkt nach `/opt/fhem/FHEM/`, der Benutzer, unter
dem FHEM läuft, braucht dort Schreibrecht.

#### Von Hand

Aus einem Klon dieses Repos:

```sh
sudo cp FHEM/74_NeatoLocal.pm /opt/fhem/FHEM/
sudo mkdir -p /opt/fhem/FHEM/lib
sudo cp FHEM/lib/NeatoLocalPlan.pm /opt/fhem/FHEM/lib/
sudo chown fhem:dialout /opt/fhem/FHEM/74_NeatoLocal.pm /opt/fhem/FHEM/lib/NeatoLocalPlan.pm
sudo chmod 644 /opt/fhem/FHEM/74_NeatoLocal.pm /opt/fhem/FHEM/lib/NeatoLocalPlan.pm
```

Dann in der FHEM-Kommandozeile:

```
reload 74_NeatoLocal.pm
define Staubsauger NeatoLocal 192.168.1.42:23
attr Staubsauger interval 60
save
```

Die Adresse darf auch fehlen: `define Staubsauger NeatoLocal` legt das Gerät an,
ohne sich zu verbinden – für den Fall, dass die Brücke erst noch geflasht werden
muss.

`reload` ist nicht optional: FHEM liest das Verzeichnis `FHEM/` beim Start ein
und kennt eine danach hinzugekommene Datei nicht – `define` scheitert sonst mit
*Cannot load module NeatoLocal*. Ein FHEM-Neustart tut es genauso. Ohne `save`
ist die Definition nach dem nächsten Neustart wieder weg.

#### Rechte am seriellen Port

Nur für den seriellen Weg nötig, bei der WLAN-Brücke entfällt er. Die Rechte an
der Moduldatei haben nichts mit dem Zugriff auf `/dev/ttyACM0` zu tun: der Port
gehört üblicherweise `root:dialout`, also muss der Benutzer, unter dem FHEM
läuft, in dieser Gruppe sein.

```sh
id fhem                          # steht dialout dabei?
sudo usermod -aG dialout fhem    # falls nicht
sudo systemctl restart fhem      # Gruppenwechsel wirkt erst nach Neustart
```

Es kann immer nur ein Prozess den Port offen haben – ein laufendes
`dump_robot.py` blockiert FHEM und umgekehrt.

### Was das Modul kann

#### Reinigen und Einstellungen

| Kommando | Wirkung |
|---|---|
| `startCleaning [house\|spot\|explore\|persistent]` | Hausreinigung (Vorgabe), Spot-Reinigung; `explore` und `persistent` siehe [unten](#explore-und-persistent-brauchen-die-app) |
| `stop` | Reinigung beenden |
| `pause` / `resume` | Reinigung unterbrechen und fortsetzen |
| `sendToBase` | zurück zur Basis |
| `findMe` | Tonsignal zum Auffinden |
| `clearError` | gemeldeten Fehler oder Hinweis quittieren |
| `navigationMode Normal\|Gentle\|Deep\|Quick` | Reinigungsmodus |
| `ecoMode on\|off` | leiser, geringere Saugleistung |
| `intenseClean on\|off` | Intensivreinigung |
| `binFullDetect on\|off` | Erkennung des vollen Staubbehälters |
| `syncTime` | Uhr des Roboters aus FHEM stellen |
| `button <name>` | beliebigen Tastendruck simulieren |
| `flashESP [<image>] [<ssid> <passwort>]` | Brücken-Firmware auf ein Board am USB-Port schreiben |
| `wifiESP <ssid> <passwort>` | einem geflashten Board neue WLAN-Zugangsdaten über USB geben |
| `otaESP [<ip>] [<image>] [force]` | die eingebaute Brücke über Funk aktualisieren |
| `buildPlan` | aus den letzten Aufzeichnungen einen gemeinsamen Grundriss rechnen |
| `statusRequest` | Zustand sofort abfragen |
| `reconnect` | Verbindung neu aufbauen |
| `testMode on\|off` | Diagnosemodus der Konsole, siehe unten |
| `raw <Kommando>` | beliebiges Konsolenkommando senden |

**`testMode`** schaltet den Roboter in den Diagnosemodus. Dort reagiert er
weder auf seine Tasten noch reinigt er. Das Modul aktiviert ihn nie von selbst
und sendet bei Shutdown, Löschen und `disable` immer `TestMode Off`.

#### Abfragen

| Abfrage | Inhalt |
|---|---|
| `help [Kommando]` | Kommandoliste des Roboters bzw. Hilfe zu einem Kommando |
| `version` | Modell, Seriennummer, Firmware |
| `state` | Zustand laut Roboter |
| `charger` | Akku- und Ladewerte |
| `battery` | Messwerte der Smart Battery |
| `warranty` | Lebensdauerzähler |
| `settings` | Benutzereinstellungen |
| `accel` | Neigung des Roboters: Readings `pitch`, `roll`, `accelSum` |
| `motors`, `sensors`, `usage`, `wifiStatus` | Rohdaten |
| `serialPorts` | serielle Schnittstellen des Rechners mit ihren by-id-Namen |
| `raw <Kommando>` | beliebiges Konsolenkommando |

#### Zustand

`state` kennt `cleaning`, `paused`, `suspended`, `docking`, `charging`,
`docked`, `idle`, `error`, `robotSilent`, `unreachable` und `disconnected`.

* **`suspended`** – der Roboter hat die Reinigung selbst unterbrochen, in aller
  Regel wegen leerem Akku, und will sie nach dem Laden fortsetzen. Steht dabei
  `isDocked 0`, hat er die Basis nicht mehr erreicht.
* **`robotSilent`** – die Verbindung zur Brücke steht, aber der Roboter
  antwortet nicht: er schläft, oder die Brücke ist noch nicht mit ihm
  verdrahtet. Nach dem Flashen ist das der normale Zustand und kein Hinweis auf
  ein Problem mit der Brücke.
* **`unreachable`** – die Verbindung selbst ist weg: die Brücke ist nicht im
  Netz oder ohne Strom.

In beiden Fällen geht die Abfrage schrittweise bis auf das 16-fache Intervall
zurück, höchstens eine Stunde, statt Zeitüberschreitungen ins Log zu schreiben.
Die erste Antwort setzt alles zurück.

`uiState` und `robotState` geben den Zustand unverändert so wieder, wie der
Roboter ihn meldet.

#### Akku

| Reading | Bedeutung |
|---|---|
| `batteryPercent` | Ladestand in Prozent |
| `batteryHealth` | Restkapazität in Prozent der Nennkapazität |
| `batteryCapacityFull`, `batteryCapacityDesign` | aktuelle und ursprüngliche Kapazität in mAh |
| `batteryCycles`, `cleaningHours` | Lebensdauerzähler |
| `batteryVoltage`, `batteryTemperature`, `batteryState` | Spannung, Temperatur, ok/low |
| `isCharging`, `isDocked` | Lade- und Dockzustand |

`batteryHealth` kommt aus der Messelektronik im Akku selbst und sagt zuverlässig
voraus, wann ein Roboter unterwegs liegenbleibt. Unterhalb von etwa 50 % schafft
er es zunehmend nicht mehr zurück zur Basis, obwohl die Ladeanzeige bis kurz
davor brauchbar aussieht:

```
define di_akku DOIF ([Staubsauger:batteryHealth] < 50) (set Nachricht Akku schwach)
```

#### Fehler und Hinweise

`error`/`errorCode` und `alert`/`alertCode` sind getrennt: ein voller
Staubbehälter (Alert 248) ist kein Fehler und setzt das Gerät nicht in den
Fehlerzustand, ein fehlender Behälter (Error 249) schon. Code 200
(`UI_ALERT_INVALID`) bedeutet „nichts zu melden“.

#### Einstellungen und Geräteangaben

`ecoMode`, `intenseClean`, `binFullDetect`, `wallFollower`, `clickSounds`,
`melodySounds`, `warningSounds`, `led`, `wifiEnabled`, `language`,
`filterChangeTime`, `brushChangeTime`, `dirtBinInterval`, `scheduleEnabled`,
`scheduledCleanings` – beim Verbinden und nach jeder Änderung gelesen.

`model`, `serialNumber`, `firmware`, `ldsSoftware`, `hardware`, `commandApi`.

`navigationMode` ist eine Ausnahme: die Konsole kennt kein Kommando, ihn
auszulesen. Das Reading hält deshalb den zuletzt gesetzten Wert. Weil der
Roboter den Modus nicht über Läufe hinweg behält, sendet das Modul ihn vor
jeder Hausreinigung erneut.

Die Reading-Namen folgen bewusst denen von `74_BOTVAC.pm`, damit bestehende
`notify`- und `DOIF`-Definitionen mit geringen Anpassungen weiterlaufen.

#### Attribute

| Attribut | Vorgabe | Bedeutung |
|---|---|---|
| `interval` | 60 | Abfrageintervall in Sekunden |
| `timeout` | 10 | wie lange auf eine Antwort gewartet wird |
| `connectTimeout` | 2 | Obergrenze für einen Verbindungsversuch |
| `espPort` | `/dev/ttyACM0` | USB-Port des Brücken-Boards beim Flashen |
| `espImage` | – | Image, das `flashESP` ohne Angabe schreibt |
| `espAppImage` | – | Anwendung, die `otaESP` ohne Angabe sendet |
| `pollState` | 1 | `GetState` mitabfragen |
| `pollErrors` | 1 | `GetErr` mitabfragen |
| `pollMotors` | 0 | `GetMotors` mitabfragen |
| `pollSettings` | 0 | Benutzereinstellungen bei jedem Durchlauf mitlesen |
| `useSetEvent` | 1 | die Event-Schnittstelle nutzen, wenn verfügbar |
| `cmdCleanHouse`, `cmdCleanSpot`, `cmdCleanExplore`, `cmdCleanPersistent`, `cmdCleanStop`, `cmdCleanPause`, `cmdCleanResume`, `cmdSendToBase`, `cmdFindMe` | – | Konsolenkommando je set-Kommando überschreiben |
| `httpPath`, `httpMethod` | `/api/serial`, POST | nur für den HTTP-Transport |
| `disable` | 0 | Verbindung schließen und Abfrage anhalten |
| `disabledForIntervals` | – | Zeitfenster, in denen das Gerät ruht (FHEM-Standardattribut) |

Die Attribute rund um Aufzeichnung und Karte stehen bei den jeweiligen
Abschnitten: `trackRuns`, `trackDir`, `trackInterval`, `trackPose`,
`trackKeepDays`, `mapInterval` und `mapMaxRange` unter
[Gefahrene Spur aufzeichnen](#gefahrene-spur-aufzeichnen), `planAuto`,
`planSources` und `planCell` unter
[Aus mehreren Läufen ein Grundriss](#aus-mehreren-läufen-ein-grundriss).

#### Brücke aus FHEM heraus einrichten

Ein fabrikneuer ESP32-C3 lässt sich vom FHEM-Rechner aus in Betrieb nehmen,
ohne Arduino-Installation und ohne dass die Zugangsdaten in der Firmware
stehen. Voraussetzung ist `esptool` (`pip3 install esptool` oder das
gleichnamige Paket der Distribution) und ein Board am USB-Port.

**Den richtigen Port finden.** Ein ESP32-C3 **und** der Roboter melden sich
beide als `/dev/ttyACM*` – die Nummer allein sagt also nichts darüber aus, was
dahintersteckt. Das Modul beantwortet die Frage selbst, auch ohne
konfigurierte Brücke:

```
get Staubsauger serialPorts
```

```
/dev/ttyACM0     ESP32 (native USB)
                 /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_9C-if00
/dev/ttyACM1     Neato robot
                 /dev/serial/by-id/usb-Neato_Robotics_Botvac_D6-if00
```

Der **by-id-Name** ist die bessere Angabe für `espPort` oder ein `define`: er
bleibt über Neustarts gleich und hängt nicht daran, in welcher USB-Buchse das
Gerät steckt. Erscheint gar kein Port, ist es meist ein reines Ladekabel ohne
Datenleitungen.

**Von einem nackten Board zum laufenden Gerät:**

```
define Staubsauger NeatoLocal
attr Staubsauger espPort /dev/ttyACM0
set Staubsauger flashESP "Mein WLAN" "lange Passphrase"
save
```

Das `define` **ohne Adresse** ist der Schlüssel: `flashESP` braucht ein Gerät,
aber die Adresse der Brücke gibt es zu diesem Zeitpunkt noch nicht. Das Gerät
steht dann im Zustand `unconfigured`, verbindet sich nicht und fragt nichts
ab. `flashESP` holt das Image, das die CI dieses Projekts baut, schreibt es,
legt die Zugangsdaten auf dem Board ab und fragt es am Ende über denselben
USB-Port, welche Adresse es im Netz bekommen hat. Die landet im Reading
`bridgeAddress`, und ein ohne Adresse definiertes Gerät trägt sie sich selbst
ein und verbindet sich. `save` hält das fest. Ein Gerät, das bereits eine
Adresse hat, behält sie – es wird nur im Log vermerkt, unter welcher Adresse
die neue Brücke erreichbar ist.

Enthalten Name oder Passwort Leerzeichen, gehören sie in Anführungszeichen.
Ein Semikolon muss als `;;` geschrieben werden, weil FHEM daran Befehle
trennt. Das Flashen läuft in einem eigenen Prozess, FHEM bleibt also bedienbar;
das Ergebnis steht im Reading `lastFlash`.

Das fertige Image liegt in [`firmware/prebuilt/`](firmware/prebuilt/) und wird
von der CI aus dem Quelltext gebaut; die Textdatei daneben nennt Version,
Commit und SHA-256. **Der FHEM-Updatemechanismus holt das Image nicht** –
`flashESP` lädt es bei Bedarf selbst. Ein eigenes Image geht vor:
`set Staubsauger flashESP /pfad/zum.bin`, oder dauerhaft über das Attribut
`espImage`.

`wifiESP` ist für den Fall, dass sich das WLAN später ändert: es übergibt die
Zugangsdaten über den USB-Port an die Konfigurationskonsole der Firmware und
meldet die neue Adresse in `bridgeAddress`. Landet das Board stattdessen in
seinem Access Point, steht in `lastFlash`, warum (Passwort abgelehnt, Netz
nicht gefunden, vom Router abgewiesen).

**Die eingebaute Brücke aktualisieren.** Im Roboter wird die Brücke von dessen
3,3-V-Schiene versorgt und hängt nicht mehr am USB-Port des Servers. Ab dann
führt der Weg über Funk:

```
set Staubsauger otaESP
```

`otaESP` holt die veröffentlichte Anwendung und schiebt sie über das
ArduinoOTA-Protokoll auf die Brücke. Die Adresse nimmt der Befehl vom Gerät;
eine abweichende lässt sich angeben: `set Staubsauger otaESP 192.168.1.150`.

**Eine Ausnahme, und sie ist wichtig:** Firmware **vor 0.4.0** hielt SSID und
Passwort als einkompilierte Konstanten *im Image*. Ein Update ersetzt dieses
Image – und damit die einzige Kopie der Zugangsdaten. Die Brücke kommt dann
ohne Netz hoch und öffnet den Access Point `neato-setup`; eingetragen werden
sie unter **http://192.168.4.1/** vom Handy aus. Kein Kabel nötig, aber jemand
muss neben dem Roboter stehen. `otaESP` liest die laufende Version und
**verweigert** ein solches Update, bis man `set <dev> otaESP force` sagt. Ab
0.4.0 liegen die Zugangsdaten im Flash und überleben jedes Update.

Wer nicht vom FHEM-Rechner aus flasht: ein Board ohne gespeicherte
Zugangsdaten öffnet den Access Point `neato-setup` mit einer Eingabeseite, und
dieselben Kommandos nimmt die Firmware auch über ein Terminal am USB-Port
entgegen (`help` listet sie). Flashen von Hand mit der Arduino-IDE beschreibt
[docs/flashing-esp32c3.md](docs/flashing-esp32c3.md). Warum sich das WLAN der
Brücke so verhält, wie es sich verhält, steht in
[docs/hintergrund.md](docs/hintergrund.md).

#### Gefahrene Spur aufzeichnen

Der Roboter führt kein eigenes Protokoll und gibt seine Wohnungskarte über die
Konsole nicht heraus. Was sich rekonstruieren lässt, ist die **gefahrene
Spur**: während eines Laufs fragt das Modul alle `trackInterval` Sekunden
`GetRobotPos` ab und schreibt jede Position als eine JSON-Zeile weg.
OpenNeato löst es genauso – dort entsteht die „Cleaning History" ebenfalls
durch Mitschreiben, nicht durch Abholen.

Die Aufzeichnung startet und endet mit dem Lauf, auch wenn er am Roboter selbst
oder per Zeitplan begonnen wurde. Eine Sitzung liegt als
`<trackDir>/<Gerät>-<Zeitstempel>.jsonl`:

```json
{"device":"Staubsauger","started":"2026-09-19_15-04-05","module":"0.16.0","unit":"m"}
{"t":1281.84,"x":0.000,"y":0.000,"th":0.0}
{"t":1284.91,"x":0.412,"y":0.003,"th":1.2}
{"summary":{"points":812,"distance":41.2,"rotation":3600,"seconds":2431}}
```

Koordinaten in Metern, `th` in Grad. Die Zusammenfassung landet zusätzlich in
den Readings `trackPoints`, `trackDistance` und `trackDuration`, der Dateiname
in `trackFile`.

**Standardmäßig ist das aus.** Es entsteht eine Datei je Lauf, und die nützt
niemandem, der sie nirgends darstellt:

```
attr Staubsauger trackRuns 1
```

Standardverzeichnis ist `./www/neato`, also `/opt/fhem/www/neato`. Fertige
Sitzungen werden nach `trackKeepDays` Tagen entfernt, Standard 14; `0` behält
alles. Gelöscht wird dabei eng umgrenzt: nur innerhalb von `trackDir`, nur
Namen im Muster `<Gerät>-<Zeitstempel>.jsonl`, nur älter als die Grenze – und
nie die Sitzung, die gerade geschrieben wird. Eigene Dateien und Sitzungen
eines anderen Geräts bleiben unangetastet.

`trackPose` bestimmt, aus welcher Position die Spur entsteht: `Smooth`
(Standard, die vom Roboter korrigierte Position) oder `Raw` – die Radencoder
allein, die über einen Lauf driften. Gemessen macht das den Unterschied
zwischen 0,156 und 0,268 belegten Zellen je Punkt; `Raw` ist nur zum
Vergleichen da.

**Lidar-Scans.** Der Lidar dreht **während eines Laufs von allein** – gemessen
an einem D6 mit rund fünf Umdrehungen je Sekunde und echten Distanzen. Im
Leerlauf steht er, und einschalten ließe er sich nur mit einem
TestMode-Kommando, in dem der Roboter nicht reinigt. `mapInterval` (Standard
0 = aus) holt alle *n* Sekunden einen `GetLDSScan` und legt ihn neben die
Spur:

```json
{"scan":{"x":1.204,"y":0.418,"th":92.0,"speed":5.02,"pts":[[0,1284],[1,1266]]}}
```

Winkel in Grad, Distanz in Millimetern, jeweils relativ zur Pose derselben
Zeile. Zeilen mit Fehlercode fallen weg, und ebenso alles jenseits von
`mapMaxRange` (Standard 6000 mm): ein echter Scan lieferte Zeilen **ohne**
Fehlercode mit rund 16,8 m, dort wo nichts zurückgestrahlt hat, während der
Lidar eines Botvac etwa fünf Meter reicht.

Wie die Punkte an ihren Platz im Raum gerechnet werden (die Formel ist
gemessen, nicht angenommen) und wie daraus ein Grundriss wird, steht in
[docs/ftui3-map.md](docs/ftui3-map.md). FHEM selbst zeichnet nichts; die
Kartenkomponente für FTUI3 ist
[fhem-ftui-components-neatomaps](https://github.com/chrisse1/fhem-ftui-components-neatomaps).
Für einen schnellen Blick ohne FHEM zeichnet `tools/render_track.py` eine
Sitzung als SVG:

```sh
python3 tools/render_track.py /opt/fhem/www/neato/Staubsauger-2026-09-20_11-59-11.jsonl
```

#### Aus mehreren Läufen ein Grundriss

Ein einzelner Lauf ist die Karte *dieses Laufs*, nicht der Wohnung: eigener
Nullpunkt, eigene Nordrichtung, und nur die Räume, in die der Roboter an dem
Tag kam. Mehrere übereinandergelegt können zweierlei, was keiner allein kann –
fehlende Wände ergänzen und über jede Zelle abstimmen lassen. Was drei von vier
Läufen Wand nennen, ist eine Wand; was einer Wand nennt, während die anderen an
dieselbe Stelle sahen und Boden fanden, war der Wäscheständer.

```
attr Staubsauger planAuto 1
set Staubsauger buildPlan
```

Das Ergebnis ist eine JSON-Datei neben den Aufzeichnungen,
`plan-<Gerät>.json`, und das Reading `planFile` nennt sie. Die FTUI-Komponente
`<ftui-neato-map view="plan">` lädt sie und zeichnet sie; Dateiformat und
Verfahren stehen in `docs/plan-format.md` des
[Komponenten-Repos](https://github.com/chrisse1/fhem-ftui-components-neatomaps).

| Attribut | Vorgabe | Bedeutung |
|---|---|---|
| `planAuto` | 0 | nach jeder Reinigung neu rechnen |
| `planSources` | 8 | wie viele Aufzeichnungen eingehen, die neuesten zuerst |
| `planCell` | 0.10 | Zellgröße in Metern; steht in der Datei, die Anzeige übernimmt sie |

**Es dauert.** Jeder Lauf wird gegen den Rahmen gedreht und geschoben, bis er
passt, und zwar über *alle* Drehungen – gemessen rund eine Minute je
Aufzeichnung auf einem gewöhnlichen Rechner, auf einem kleinen Board
entsprechend länger. Das läuft in einem eigenen, heruntergestuften Prozess;
FHEM selbst hält nichts an. Wer es kürzer braucht, nimmt weniger
`planSources`.

Läufe, die nicht passen, werden **abgelehnt** statt hineingezwungen – eine
andere Etage in denselben Rahmen zu pressen zieht Wände quer durch Räume.

```
planState   ok
            ok, 1 did not fit (0.33)
            ok, 2 did not fit (0.41, 0.33)
            failed: <Grund>
```

Die Zahl in Klammern ist die erreichte Güte. **Dieses Reading lohnt sich
mitzuloggen:** die Schwelle, unter der ein Lauf verworfen wird (0,45), ist eine
Annahme und keine Messung, und die Belege widersprechen sich noch – drei echte
Läufe derselben Wohnung kamen auf 0,64 bis 1,0, ein Teillauf gegen einen vollen
aber auf 0,33. Über ein paar Wochen ist `planState` die Reihe, die das
entscheidet. Dieselben Zahlen stehen im Feld `scores` der Plandatei.

Von Hand, ohne FHEM, geht dasselbe mit

```sh
perl tools/neato_plan.pl /opt/fhem/www/neato Staubsauger
```

**Irrläufer.** Vereinzelt liegt ein Punkt hinter einer Wand. Naheliegend ist
der Verdacht, dass der Roboter an Engstellen kippt, deshalb trägt seit 0.22.0
jeder Scan auch die Neigung (`"tilt":[Pitch, Roll, |a|]`, von Hand mit
`get <dev> accel`). Über einen vollen Lauf gemessen erklärt die Neigung die
Irrläufer **nicht** (Korrelation +0,05); es sind einzelne schwache
Rückläufer auf große Entfernung, und das Belegungsgitter fängt sie schon ab.
Einen Neigungsfilter gibt es deshalb bewusst nicht. `tools/stray_points.py`
rechnet das auf jeder Sitzung nach, die ganze Messung steht in
[docs/ftui3-map.md](docs/ftui3-map.md).

#### Explore und Persistent brauchen die App

`startCleaning explore` und `startCleaning persistent` beschreibt die Hilfe des
Roboters selbst als Entsprechung zum Start aus der Smart App – bei `house` und
`spot` tut sie das nicht. An einem D6 ohne Cloud beobachtet: das Kommando wird
angenommen, der Roboter setzt Alarm 236 `UI_ALERT_ACQUIRING_PERSISTENT_MAP_IDS`
und fährt nicht los.

**Schlimmer noch:** Danach nimmt der Roboter weitere Reinigungsbefehle an, ohne
etwas zu tun. Auch `startCleaning house` läuft dann ins Leere, bis der Roboter
**aus- und wieder eingeschaltet** wird. Ein Explore-Versuch kostet also nicht
nur sich selbst, sondern den nächsten Lauf.

Beide Modi werden deshalb abgelehnt, solange nicht `force` angehängt wird:

```
set Staubsauger startCleaning explore force
```

Die Konsole kennt keinen Befehl, um persistente Karten-IDs anzulegen,
zuzuweisen oder abzufragen. Die Vermutung liegt daher nahe, dass diese IDs von
der Cloud kamen – belegt ist das nicht, nur das beobachtete Verhalten. `house`
und `spot` laufen normal.

#### Wie die Kommandos zum Roboter kommen

Die `Help`-Ausgabe des Roboters ist nicht vollständig. Pause, Fortsetzen und
Rückkehr zur Basis laufen über `SetEvent`, die authentifizierte
Event-Schnittstelle, über die früher die Cloud den Roboter gesteuert hat und
die in keiner Kommandoliste auftaucht. Ihr Schlüssel wird aus der MAC-Adresse
berechnet, die `GetVersion` mitliefert.

| set-Kommando | Weg |
|---|---|
| `startCleaning`, `stop` | `SetEvent`, sonst `Clean House` / `Clean Stop` |
| `pause` / `resume` | `SetEvent`, ohne Schlüssel `SetButton start` als Umschalter |
| `sendToBase` | **nur** `SetEvent` – die dokumentierten Kommandos bieten dafür nichts |
| `findMe` | `PlaySound SoundID 20` |

Das Reading `commandApi` zeigt, ob die Schnittstelle freigeschaltet ist
(`setEvent` oder `legacy`). `attr <dev> useSetEvent 0` erzwingt die
dokumentierten Kommandos.

Gefunden und entschlüsselt hat die Event-Schnittstelle, `GetState` und die
übrigen undokumentierten Kommandos das Projekt
[OpenNeato](https://github.com/renjfk/OpenNeato) (MIT, © 2026 Soner Köksal).
Dieses Modul enthält eine eigenständige Perl-Umsetzung, die gegen deren
C++-Original auf bekannten Werten geprüft ist. Alle Einzelheiten stehen in
[docs/serial-commands.md](docs/serial-commands.md).

#### Was nicht geht

* **No-Go-Linien und Zonenreinigung.** Der D6 konnte sie in der App, aber sie
  kamen über seine Cloud – `GetVersion` nennt sie im Klartext,
  `nucleo.neatocloud.com` –, und die ist abgeschaltet. Keines der 44 Kommandos
  in der Hilfe der Konsole hat mit Karten zu tun. Was bekannt ist, was nur
  unbelegt ist und welche Wege offen bleiben, steht in
  [docs/serial-commands.md](docs/serial-commands.md#no-go-linien-was-bekannt-ist-und-was-nicht).
  Die einzige Lösung, die heute funktioniert, ist Neatos Magnetband.
* **Firmware-Updates des Roboters.** Gab es nur über die Cloud.
* **Die Karte des Roboters auslesen.** Die Konsole bietet dafür kein Kommando.

### Werkzeuge

#### Konsole eines Roboters auslesen

`tools/dump_robot.py` fragt den Roboter nach seiner Kommandoliste, holt zu jedem
genannten Kommando den Hilfetext und dazu die Ausgaben der harmlosen `Get*`-
Kommandos. Das Ergebnis dokumentiert, was die jeweilige Firmware versteht.

```
python3 tools/dump_robot.py --device /dev/ttyACM0
python3 tools/dump_robot.py --tcp 192.168.1.42:23
python3 tools/dump_robot.py --device /dev/ttyACM0 --diagnose
```

Das Skript liest nur: es sendet ausschließlich `Help` und `Get*`. Kein
`TestMode`, keine Motorkommandos, keine Einstellungsänderungen. Seriennummern
werden maskiert, damit sich ein Dump gefahrlos weitergeben lässt
(`--no-redact` schaltet das ab). Es braucht nur ein normales Python 3;
pyserial ist nicht nötig.

**Wer ein anderes Modell als den D6 hat: ein Dump davon ist der wertvollste
Beitrag.** Alles, was das Modul über die Konsole weiß, stammt von einem
einzigen Roboter.

`--diagnose` prüft Gerät, Rechte und belegende Prozesse, meldet die USB-Kennung,
hört fünf Sekunden passiv mit und probiert alle drei Zeilenenden durch, jeweils
mit Hexdump. Die häufigsten Ursachen für eine stumme Konsole sind, in dieser
Reihenfolge: ein schlafender Roboter, der falsche Port, ein belegter Port und
ein Ladekabel ohne Datenleitungen.

#### Ohne Roboter ausprobieren

`tools/neato_sim.py` emuliert die Konsole eines Botvac über TCP, mit
Kommando-Echo, `Ctrl-Z`-Terminator, den CSV-Ausgaben des echten Geräts und
plausiblem Verhalten: der Akku entlädt sich beim Saugen und lädt in der Basis.

```
python3 tools/neato_sim.py
```

```
define Staubsauger NeatoLocal 127.0.0.1:8888
```

Mit `--usb` verweigert der Simulator die Reinigung mit Fehler 220 wie ein
Roboter mit angestecktem USB-Host.

### Die Testreihe

```
perl tools/check_module.pl        # Modul: Laden, Transporte, Parser, Zustandslogik
perl tools/check_ota.pl           # Update über Funk, gegen einen Stellvertreter der Brücke
python3 tools/check_sim.py        # Simulator: Protokoll und Zustandsübergänge
python3 tools/check_dump.py       # Dump-Werkzeug, seriell über ein PTY und über TCP
python3 tools/check_track.py      # Sitzungsformat und Koordinatenkonvention
python3 tools/check_partition.py  # Partitionstabelle des Images
perl tools/check_plan.pl          # Grundriss gegen den Referenzfall (dauert eine Minute)
perl tools/check_plan.pl --quick  # davon nur die schnellen Prüfungen
```

`check_plan.pl` baut den Referenzfall aus `docs/reference-plan/` neu und hält
das Ergebnis gegen das, was die JavaScript-Referenz aus denselben drei
Aufzeichnungen macht. Verlangt wird keine Gleichheit bis auf die Zelle – die
Schranken stehen in `docs/plan-format.md` des Komponenten-Repos.

Alle laufen ohne FHEM-Installation und ohne Roboter. Die Testdaten sind
wörtliche Konsolenausgaben eines BotVac D6. Die CI führt sie bei jedem Push aus
und übersetzt zusätzlich die Brücken-Firmware für den ESP32-C3.

### Wenn etwas klemmt

**FHEM bleibt kurz stehen.** FHEM baut TCP-Verbindungen synchron auf; solange
ein Verbindungsversuch läuft, steht der ganze Prozess. Die Brücke wird vom
Roboter versorgt und ist weg, sobald er aus ist. Das Modul begrenzt den Versuch
auf 2 Sekunden, `connectTimeout` senkt das weiter. `apptime` in der
FHEM-Kommandozeile weist es nach: erscheint dort `NeatoLocal_Ready` oder
`DevIo_OpenDev` mit langer Laufzeit, ist es der Verbindungsaufbau.

**Der Roboter antwortet nicht.** `state` steht auf `robotSilent`: Roboter
wecken, Verdrahtung der Brücke prüfen (`http://neato.local/` zeigt die
Byte-Zähler in beide Richtungen), oder `--diagnose` am USB-Port laufen lassen.

**Die Brücke ist weg.** `state` steht auf `unreachable`: die Verbindung kommt
nicht zustande. Stromversorgung und WLAN prüfen, nicht die Verdrahtung zum
Roboter.

**Ein Kommando bleibt wirkungslos.** `get <dev> help Clean` zeigt, was die
jeweilige Firmware versteht; über die `cmd*`-Attribute lässt sich jedes
Kommando anpassen.

### Hintergrund

Warum einiges so gebaut ist, wie es gebaut ist – WLAN der Brücke, Flashen,
Updates –, steht getrennt in [docs/hintergrund.md](docs/hintergrund.md). Die
Konsolenkommandos stehen in [docs/serial-commands.md](docs/serial-commands.md),
die Karte in [docs/ftui3-map.md](docs/ftui3-map.md) und die Hardware in
[docs/hardware.md](docs/hardware.md).

### Lizenz

GPLv2, wie FHEM selbst – der vollständige Text liegt in [LICENSE](LICENSE).

Die SKey-Berechnung für die `SetEvent`-Kommandos ist eine eigenständige
Neuimplementierung dessen, was [OpenNeato](https://github.com/renjfk/OpenNeato)
(MIT, © 2026 Soner Köksal) reverse engineered hat, gegen dessen C++-Original an
bekannten Werten geprüft.
