#!/usr/bin/env python3
"""
Neato Botvac console simulator.

Speaks the same serial protocol as a real Botvac -- command echo, CSV output,
response terminated by Ctrl-Z (0x1A) -- but over TCP. Lets you develop and test
74_NeatoLocal.pm end to end without a robot and without any hardware.

    python3 tools/neato_sim.py                  # listens on 127.0.0.1:8888
    python3 tools/neato_sim.py --port 8888 --usb # also simulates the USB error 220

In FHEM:

    define Staubsauger NeatoLocal 127.0.0.1:8888

The simulated robot keeps a plausible state: it discharges while cleaning,
charges while docked, leaves the base when cleaning starts and returns when it
is stopped.
"""

import argparse
import re
import socketserver
import threading
import time

EOR = b"\x1a"  # the console terminates every response with Ctrl-Z


class Robot:
    """Minimal but self-consistent Botvac state."""

    def __init__(self, usb_attached=False):
        self.lock = threading.Lock()
        self.usb_attached = usb_attached
        self.cleaning = False
        self.paused = False
        self.docked = True
        self.fuel = 96.0
        self.error = None
        self.alert = None
        self.test_mode = False
        self.nav_mode = "Normal"
        self.settings = {"EcoMode": "OFF", "IntenseClean": "OFF",
                         "BinFullDetect": "ON"}
        self.last = time.monotonic()

    def _advance(self):
        """Move battery and dock state forward in time."""
        now = time.monotonic()
        elapsed = now - self.last
        self.last = now

        if self.cleaning:
            self.fuel = max(0.0, self.fuel - elapsed * 0.5)
            if self.fuel <= 10.0:
                # a real robot heads home when the battery runs low
                self.cleaning = False
                self.docked = True
        elif self.docked:
            self.fuel = min(100.0, self.fuel + elapsed * 1.0)

    def snapshot(self):
        with self.lock:
            self._advance()
            return {
                "fuel": int(self.fuel),
                "cleaning": self.cleaning,
                "docked": self.docked,
                "charging": self.docked and self.fuel < 100.0,
                "error": self.error,
                "alert": self.alert,
                "paused": self.paused,
                "test_mode": self.test_mode,
            }

    def start_cleaning(self):
        with self.lock:
            self._advance()
            if self.usb_attached:
                # the real robot refuses to clean with a USB host attached
                self.error = (220, "UI_ERROR_USB_CONNECTED")
                return False
            if self.test_mode:
                # test mode disables the normal cleaning behaviour
                return False
            self.cleaning = True
            self.paused = False
            self.docked = False
            self.error = None
            return True

    def stop_cleaning(self):
        with self.lock:
            self._advance()
            self.cleaning = False
            self.paused = False

    def press_button(self, button):
        """Simulate a UI button. Start toggles pause, IRhome sends it home."""
        with self.lock:
            self._advance()
            button = button.lower()
            if button == "start":
                if self.cleaning:
                    self.cleaning = False
                    self.paused = True
                elif self.paused:
                    self.cleaning = True
                    self.paused = False
                return True
            if button in ("irhome", "back"):
                self.cleaning = False
                self.paused = False
                self.docked = True
                return True
            return button in ("soft", "spot", "up", "down", "irstart",
                              "irspot", "irfront", "irback", "irleft",
                              "irright", "ireco")

    def set_test_mode(self, on):
        with self.lock:
            self.test_mode = on
            if on:
                self.cleaning = False


HELP_TEXT = """Help - Without any argument, this prints a list of all possible cmds.
With a command name, it prints the help for that particular command
Clean - Starts a cleaning by simulating press of start button.
ClearFiles - Erases Black Box, and other Logs
DiagTest - Executes different test modes. Once set, press Start button to engage. (Test modes are mutually exclusive.)
GetCharger - Get the diagnostic data for the charging system.
SetNavigationMode - Sets the Navigation Mode
GetAccel - Get the Accelerometer readings.
GetAnalogSensors - Get the A2D readings for the analog sensors.
GetButtons - Get the state of the UI Buttons.
GetCalInfo - Prints out the cal info from the System Control Block.
GetDigitalSensors - Get the state of the digital sensors.
GetErr - Get Error Message.
GetLDSScan - Get scan packet from LDS.
GetMotors - Get the diagnostic data for the motors.
GetSensor - Gets the sensors status ON/OFF (Wall Follower and Ultra Sound Only)
GetTime - Get Current Scheduler Time.
GetVersion - Get the version information for the system software and hardware.
GetWarranty - Get the warranty data.
GetUserSettings - Get the user settings.
GetUsage - Get usage settings
PlaySound - Play the specified sound in the robot.
SetButton - Simulates a button press.
SetFuelGauge - Set Fuel Gauge Level.
SetTime - Sets the current day, hour, and minute for the scheduler clock.
SetUserSettings - Sets user settings
TestMode - Sets TestMode on or off. Some commands can only be run in TestMode."""

HELP_CLEAN = """Clean - Starts a cleaning by simulating press of start button.
    Explore - (Optional) Equivalent to starting an Exploration run from the Smart App.
\t\tStarts an exploration run.

    House - (Optional) Equivalent to pressing 'Start' button once.
\t\tStarts a house cleaning.
\t\t(House cleaning mode is the default cleaning mode.)
\t\t(Choose only 1 of House,Spot,Stop)
    Spot - (Optional) Starts a spot clean. (Not available with AutoCycle)
(Choose only 1 of Explore,House,Spot,Stop)
    Persistent - (Optional) Equivalent to starting a persistent cleaning from the Smart App.

    Stop - Stop Cleaning.
(Choose only 1 of Explore,Persistent,House,Spot,Stop)"""

HELP_SETBUTTON = """SetButton - Simulates a button press.
    soft - Simulate pressing the soft button
    start - Simulate pressing the start button
    spot - Simulate pressing the spot button
    back - Simulate pressing the back button
    IRhome - Simulate pressing the down button
    IReco - Simulate pressing the down button"""

VERSION_TEXT = """Component,Major,Minor,Build,Aux
BaseID,0.0,0.0,0,0,
Beehive URL, beehive.neatocloud.com,
BlowerType,1,BLOWER_ORIG,
Bootloader Version,90c973a5,,
BrushSpeed,1400,,
ChassisRev,1,,
LDS CPU,F2802x/c001,,
LDS Serial,KSH12345,,
LDS Software,V2.7.4,0000000000,
Locale,1,LOCALE_USA,
MainBoard Serial Number,GPC26519,40bd32d1097a,
MainBoard Version,4,,
Model,BotVacD6Connected,905-0496,
NTP URL, pool.ntp.org,
Nucleo URL, nucleo.neatocloud.com,
QAState,QA_STATE_APPROVED
Serial Number,KSH12345,aabbccddeeff,P
SideBrushType,2,SIDE_BRUSH_PRESENT,
Software Git SHA,14f004c
Software,4,5,3,189,0
VacuumPwr,70,,
WheelPodType,1,WHEEL_POD_ORIG,"""


SIM_SERIAL = "KSH12345,aabbccddeeff,P"


def compute_skey(serial):
    """The event API's key, as the firmware derives it from the MAC."""
    comma = serial.find(",")
    if comma < 0:
        return ""
    mac = serial[comma + 1:comma + 13]
    if len(mac) != 12:
        return ""

    seed = [0x68, 0x36, 0x43, 0x58, 0x09, 0x09, 0x3A, 0x3C, 0x2A, 0x7B, 0x59]
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + seed[i % 11]) & 0xFF
        s[i], s[j] = s[j], s[i]

    ks = []
    i = j = 0
    for _ in range(12):
        i = (i + 1) & 0xFF
        j = (j + s[i]) & 0xFF
        s[i], s[j] = s[j], s[i]
        ks.append(s[(s[i] + s[j]) & 0xFF])

    key = "".join("%02x" % (k ^ ord(c)) for k, c in zip(ks, mac))
    return key + key[6]


def charger_text(state):
    return "\n".join([
        "Label,Value",
        "FuelPercent,%d" % state["fuel"],
        "BatteryOverTemp,0",
        "ChargingActive,%d" % (1 if state["charging"] else 0),
        "ChargingEnabled,%d" % (1 if state["docked"] else 0),
        "ConfidentOnFuel,1",
        "OnReservedFuel,%d" % (1 if state["fuel"] < 15 else 0),
        "EmptyFuel,%d" % (1 if state["fuel"] < 5 else 0),
        "BatteryFailure,0",
        "ExtPwrPresent,%d" % (1 if state["docked"] else 0),
        "ThermistorPresent,1",
        "BattTempCAvg,27",
        "VBattV,%.2f" % (14.0 + state["fuel"] * 0.023),
        "VExtV,%.2f" % (20.98 if state["docked"] else 0.0),
        "Charger_mAH,0",
        "Discharge_mAH,149",
    ])


def motors_text(state):
    rpm = 2100 if state["cleaning"] else 0
    return "\n".join([
        "Parameter,Value",
        "Brush_RPM,%d" % (1400 if state["cleaning"] else 0),
        "Brush_mA,%d" % (280 if state["cleaning"] else 0),
        "Vacuum_RPM,%d" % rpm,
        "Vacuum_mA,%d" % (300 if state["cleaning"] else 0),
        "LeftWheel_RPM,%d" % (30 if state["cleaning"] else 0),
        "LeftWheel_Load%,0",
        "LeftWheel_PositionInMM,0",
        "LeftWheel_Speed,0",
        "RightWheel_RPM,%d" % (30 if state["cleaning"] else 0),
        "RightWheel_Load%,0",
        "RightWheel_PositionInMM,0",
        "RightWheel_Speed,0",
        "ROTATION_SPEED,0.00",
        "SideBrush_mA,0",
    ])


def accel_text(state):
    """GetAccel, shaped like a real D6's answer.

    The values are the ones a D6 reports standing level on its base: not zero
    and not one g, because the sensor carries no calibration (GetCalInfo shows
    XAccel/YAccel/ZAccel all 0). Anything reading these has to work off a
    resting value rather than off zero, and a simulator that answered with a
    tidy 0.00 / 0.00 / 1.000 would hide exactly that.
    """
    return (
        "Label,Value\n"
        "PitchInDegrees, -2.33\n"
        "RollInDegrees, -1.20\n"
        "XInG, 0.039\n"
        "YInG,-0.020\n"
        "ZInG, 0.950\n"
        "SumInG, 0.951"
    )


def handle_command(robot, line):
    """Return the console output for one command line."""
    cmd = line.strip()
    low = cmd.lower()
    state = robot.snapshot()

    if low == "" or low == "wake-up":
        return ""

    if low.startswith("help"):
        arg = cmd[4:].strip().lower()
        if arg == "clean":
            return HELP_CLEAN
        if arg == "setbutton":
            return HELP_SETBUTTON
        return HELP_TEXT

    if low.startswith("clean"):
        arg = low[5:].strip()
        if arg in ("", "house"):
            if not robot.start_cleaning():
                return "Cannot start cleaning."
            return ""
        if arg in ("spot", "explore", "persistent"):
            if not robot.start_cleaning():
                return "Cannot start cleaning."
            return ""
        if arg == "stop":
            robot.stop_cleaning()
            return ""
        return "Unknown argument to Clean: %s" % arg

    if low.startswith("testmode"):
        arg = low[8:].strip()
        if arg == "on":
            robot.set_test_mode(True)
            return ""
        if arg == "off":
            robot.set_test_mode(False)
            return ""
        return "TestMode requires On or Off"

    if low == "getaccel":
        return accel_text(state)

    if low == "getcharger":
        return charger_text(state)

    if low == "getmotors":
        return motors_text(state)

    if low == "getversion":
        return VERSION_TEXT

    if low.startswith("geterr"):
        if low[6:].strip() == "clear":
            with robot.lock:
                robot.error = None
            return ""
        # An empty slot is not an absent line: the firmware fills it with
        # code 200 / UI_ALERT_INVALID.
        empty = "200 -  (UI_ALERT_INVALID)"
        lines = ["Error"]
        lines.append("%d -  (%s)" % state["error"] if state["error"] else empty)
        lines.append("Alert")
        lines.append("%d -  (%s)" % state["alert"] if state["alert"] else empty)
        lines.append("USB state ")
        lines.append(" NOT connected")
        return "\n".join(lines)

    if low == "getanalogsensors":
        return "\n".join([
            "SensorName,Value",
            "WallSensorInMM,40",
            "BatteryVoltageInmV,%d" % int(14000 + state["fuel"] * 23),
            "LeftDropInMM,60",
            "RightDropInMM,60",
            "VacuumCurrentInmA,%d" % (300 if state["cleaning"] else 0),
        ])

    if low.startswith("playsound"):
        return ""

    if low.startswith("setbutton"):
        arg = cmd[9:].strip()
        if not arg:
            return "SetButton requires a button name"
        if not robot.press_button(arg):
            return "Unknown button: %s" % arg
        return ""

    if low.startswith("setnavigationmode"):
        arg = cmd[17:].strip().capitalize()
        if arg not in ("Normal", "Gentle", "Deep", "Quick"):
            return "Unknown navigation mode"
        with robot.lock:
            robot.nav_mode = arg
        return ""

    if low.startswith("settime"):
        return ""

    if low == "gettime":
        return "Sunday 0:00:00"

    if low == "getstate":
        if state["paused"]:
            ui, rs = "UIMGR_STATE_CLEANINGPAUSED", "ST_C_Paused"
        elif state["cleaning"]:
            ui, rs = "UIMGR_STATE_STARTHOUSECLEANING", "ST_C_Cleaning"
        elif state["docked"]:
            ui, rs = "UIMGR_STATE_STANDBY", "ST_M2_Charging_StdBy"
        else:
            ui, rs = "UIMGR_STATE_STANDBY", "ST_C_Standby"
        return "Current UI State is: %s\nCurrent Robot State is: %s" % (ui, rs)

    if low.startswith("setevent"):
        # "SetEvent event <NAME> SKey <key>" -- a wrong key is refused, which is
        # what makes this worth simulating at all.
        m = re.match(r"setevent\s+event\s+(\S+)\s+skey\s+(\S+)\s*$", low)
        if not m:
            return "Usage: SetEvent event <event> SKey <key>"
        event, key = m.group(1).upper(), m.group(2)
        if key != compute_skey(SIM_SERIAL).lower():
            return "Invalid SKey"
        if event.endswith("START_HOUSE_CLEANING") or event.endswith("START_SPOT_CLEANING"):
            return "" if robot.start_cleaning() else "Cannot start cleaning."
        if event.endswith("PAUSE_CLEANING"):
            robot.press_button("start")
            return ""
        if event.endswith("RESUME_CLEANING"):
            robot.press_button("start")
            return ""
        if event.endswith("STOP_CLEANING"):
            robot.stop_cleaning()
            return ""
        if event.endswith("SEND_TO_BASE"):
            robot.press_button("irhome")
            return ""
        return "Unknown event: %s" % event

    if low == "getusersettings":
        with robot.lock:
            cfg = dict(robot.settings)
        # spelled and spaced exactly like the real firmware, trailing blanks
        # included -- that is what the parser has to cope with
        return "\n".join([
            "Language, EL_NONE ",
            "ClickSounds, ON ",
            "LED, ON ",
            "Wall Enable, ON ",
            "Eco Mode, %s " % cfg["EcoMode"],
            "IntenseClean, %s " % cfg["IntenseClean"],
            "WiFi, OFF ",
            "Melody Sounds, ON ",
            "Warning Sounds, ON ",
            "Bin Full Detect, %s " % cfg["BinFullDetect"],
            "Filter Change Time (seconds), 43200 ",
            "Brush Change Time (seconds), 259200 ",
            "Dirt Bin Alert Reminder Interval (minutes), 90 ",
            "Current Dirt Bin Runtime is: 0",
            "Schedule is Disabled",
            "Sun 00:00 -None-",
        ])

    if low.startswith("setusersettings"):
        parts = cmd.split()
        if len(parts) < 3:
            return "SetUserSettings requires a key and a value"
        key, value = parts[1], parts[2].upper()
        match = [k for k in ("EcoMode", "IntenseClean", "BinFullDetect")
                 if k.lower() == key.lower()]
        if not match:
            return "Unknown setting: %s" % key
        if value not in ("ON", "OFF"):
            return "Value must be ON or OFF"
        with robot.lock:
            robot.settings[match[0]] = value
        return ""

    if low.startswith("getcharger info"):
        return "\n".join([
            "Label,Value",
            "Manufacturer Name, Panasonic",
            "Device Chemistry, LION1",
            "Capacity Mode, mA",
            "Design Capacity mA,4200",
            "Design Voltage,14400",
        ])

    if low.startswith("getcharger data"):
        # capacity fades with the cycle count, so the health reading has
        # something to move
        full = max(400, 4200 - 2 * 1484)
        return "\n".join([
            "Label,Value",
            "Voltage mV,%d" % int(14000 + state["fuel"] * 23),
            "Current mA,0",
            "Temperature deciC,26600",
            "Relative State of Charge( batt_full%% ),%d" % state["fuel"],
            "Remaining Capacity mA,%d" % int(full * state["fuel"] / 100),
            "Full Charge Capacity mA,%d" % full,
            "Cycle Count,1484",
            "Status,640",
            "Error,0",
        ])

    if low == "getwarranty":
        return "\n".join([
            "Item,Value",
            "CumulativeCleaningTimeInSecs,00192364",
            "CumulativeBatteryCycles,05c2",
            "ValidationCode,c2cc3e78",
        ])

    if low == "getusage":
        return "\n".join([
            "Item,Value",
            "TotalCleanTime,192364",
            "TotalCleanArea,1204000",
            "MainBrushArea,845000",
            "SideBrushArea,845000",
            "DustbinTime,90",
            "FilterArea,845000",
        ])

    return "Unknown Command: %s" % cmd


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        robot = self.server.robot
        peer = "%s:%d" % self.client_address
        print("[sim] client connected: %s" % peer, flush=True)

        # a real robot greets you with its prompt
        self.wfile.write(b"\r\n" + EOR)

        try:
            for raw in self.rfile:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.strip() == "":
                    continue
                print("[sim] <- %s" % line, flush=True)
                out = handle_command(robot, line)
                # the console echoes the command, then the output, then Ctrl-Z
                payload = line + "\r\n"
                if out:
                    payload += out.replace("\n", "\r\n") + "\r\n"
                self.wfile.write(payload.encode("utf-8") + EOR)
                self.wfile.flush()
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            print("[sim] client gone: %s" % peer, flush=True)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description="Neato Botvac console simulator")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8888)
    ap.add_argument("--usb", action="store_true",
                    help="simulate an attached USB host: cleaning fails with error 220")
    args = ap.parse_args()

    server = Server((args.host, args.port), Handler)
    server.robot = Robot(usb_attached=args.usb)

    print("[sim] Neato console on %s:%d%s"
          % (args.host, args.port, " (USB attached, error 220)" if args.usb else ""),
          flush=True)
    print("[sim] FHEM: define Staubsauger NeatoLocal %s:%d" % (args.host, args.port),
          flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[sim] shutting down", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
