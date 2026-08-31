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
        self.docked = True
        self.fuel = 96.0
        self.error = None
        self.test_mode = False
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
                "test_mode": self.test_mode,
            }

    def start_cleaning(self):
        with self.lock:
            self._advance()
            if self.usb_attached:
                # the real robot refuses to clean with a USB host attached
                self.error = (220, "Please put my Dirt Bin back in.")
                return False
            if self.test_mode:
                # test mode disables the normal cleaning behaviour
                return False
            self.cleaning = True
            self.docked = False
            self.error = None
            return True

    def stop_cleaning(self):
        with self.lock:
            self._advance()
            self.cleaning = False

    def set_test_mode(self, on):
        with self.lock:
            self.test_mode = on
            if on:
                self.cleaning = False


HELP_TEXT = """Help - Without any argument, this prints a list of all possible cmds.
Clean - Starts a cleaning by simulating press of start button.
GetAccel - Get the Accelerometer readings.
GetAnalogSensors - Get the A2D readings for the analog sensors.
GetButtons - Get the state of the UI Buttons.
GetCalInfo - Prints out the cal info from the System Control Block.
GetCharger - Get the diagnostic data for the charging system.
GetDigitalSensors - Get the state of the digital sensors.
GetErr - Get Error Message.
GetLDSScan - Get scan packet from LDS.
GetLifeStatLog - Get All Life Stat Logs.
GetMotors - Get the diagnostic data for the motors.
GetSchedule - Get the Cleaning Schedule.
GetTime - Get Current Scheduler Time.
GetUserSettings - Get user settings.
GetVersion - Get the version information for the system software and hardware.
GetWarranty - Get the warranty validation codes.
PlaySound - Play the specified sound in the robot.
RestoreDefaults - Restore user settings to default.
SetTime - Sets the current day, hour, and minute for the scheduler clock.
TestMode - Sets TestMode on or off."""

HELP_CLEAN = """Clean - Starts a cleaning by simulating press of start button.
  House - Start a house cleaning.
  Spot - Start a spot clean.
  Stop - Stop cleaning."""

VERSION_TEXT = """Component,Major,Minor,Build,
ModelID,-1,BotvacD7Connected,,
ConfigID,1,,,
Serial Number,KSH12345-0000123,,,
Software,3,4,,
BatteryType,1,LIION_4CELL,,
BlowerType,1,BLOWER_ORIG,,
BrushSpeed,1200,,,
LDS Software,V2.6.15295,,,
LDS Serial,KSH12345,,,
MainBoard Vendor ID,505,,,
BootLoader Software,18119,,,
MainBoard Software,10199,,,
MainBoard Version,4,0,,
ChassisRev,2,,,
UIPanelRev,1,,,"""


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
        "ThermistorPresent[0],1",
        "ThermistorPresent[1],1",
        "BatteryTempCAvg[0],25",
        "BatteryTempCAvg[1],25",
        "VBattV,%.2f" % (14.0 + state["fuel"] * 0.023),
        "VExtV,%.2f" % (20.98 if state["docked"] else 0.0),
        "Charger_mAH,0",
    ])


def motors_text(state):
    rpm = 2100 if state["cleaning"] else 0
    return "\n".join([
        "Label,Value",
        "Brush_RPM,%d" % (1200 if state["cleaning"] else 0),
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
        "Charger_mAH,0",
        "SideBrush_mA,0",
    ])


def handle_command(robot, line):
    """Return the console output for one command line."""
    cmd = line.strip()
    low = cmd.lower()
    state = robot.snapshot()

    if low == "" or low == "wake-up":
        return ""

    if low.startswith("help"):
        arg = cmd[4:].strip().lower()
        return HELP_CLEAN if arg == "clean" else HELP_TEXT

    if low.startswith("clean"):
        arg = low[5:].strip()
        if arg in ("", "house"):
            if not robot.start_cleaning():
                return "Cannot start cleaning."
            return ""
        if arg == "spot":
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

    if low == "getcharger":
        return charger_text(state)

    if low == "getmotors":
        return motors_text(state)

    if low == "getversion":
        return VERSION_TEXT

    if low == "geterr":
        if state["error"]:
            return "%d - %s" % state["error"]
        return ""

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
