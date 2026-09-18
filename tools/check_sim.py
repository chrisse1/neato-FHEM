#!/usr/bin/env python3
"""
Protocol check for tools/neato_sim.py.

Verifies the simulator against the exact rules 74_NeatoLocal.pm relies on:
command echo, Ctrl-Z terminator, CSV field layout and the state transitions the
module derives its readings from. Run: python3 tools/check_sim.py
"""

import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import neato_sim  # noqa: E402

EOR = b"\x1a"
FAILED = []


def check(cond, label):
    print(("ok   " if cond else "FAIL ") + label)
    if not cond:
        FAILED.append(label)


class Client:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.buf = b""
        self.read_response()  # consume the greeting

    def read_response(self):
        while EOR not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise EOFError("connection closed")
            self.buf += chunk
        raw, self.buf = self.buf.split(EOR, 1)
        return raw.decode("utf-8", "replace")

    def send(self, cmd):
        self.sock.sendall((cmd + "\n").encode("utf-8"))
        raw = self.read_response()
        # the module strips the echoed command the same way
        body = raw.lstrip("\r\n")
        if body.lower().startswith(cmd.lower()):
            body = body[len(cmd):].lstrip("\r\n")
        return body.strip()

    def csv(self, cmd):
        values = {}
        for line in self.send(cmd).splitlines():
            fields = line.split(",")
            if len(fields) >= 2:
                values[fields[0].strip()] = fields[1].strip()
        return values

    def close(self):
        self.sock.close()


def main():
    server = neato_sim.Server(("127.0.0.1", 0), neato_sim.Handler)
    server.robot = neato_sim.Robot()
    host, port = server.server_address
    threading.Thread(target=server.serve_forever, daemon=True).start()

    c = Client(host, port)

    raw = c.send("GetVersion")
    check("GetVersion" not in raw, "response starts after the echoed command")

    version = c.csv("GetVersion")
    check(version.get("Serial Number") == "KSH12345", "GetVersion carries the serial number")
    check(version.get("Model") == "BotVacD6Connected", "GetVersion carries the model")
    check("Software" in version, "GetVersion carries the firmware version")

    charger = c.csv("GetCharger")
    check(charger.get("FuelPercent", "").isdigit(), "FuelPercent is numeric")
    check(charger.get("ExtPwrPresent") == "1", "robot starts docked")

    check(c.csv("GetMotors").get("Vacuum_RPM") == "0", "vacuum is off while docked")

    # GetErr answers in sections. With nothing wrong both slots carry
    # code 200 / UI_ALERT_INVALID, which the module must not read as a fault.
    err = c.send("GetErr")
    check("Error" in err and "Alert" in err, "GetErr reports its sections")
    check(err.count("UI_ALERT_INVALID") == 2, "empty slots report UI_ALERT_INVALID")
    check("249" not in err and "248" not in err, "no real fault while idle")

    c.send("Clean House")
    check(c.csv("GetCharger").get("ExtPwrPresent") == "0", "cleaning leaves the base")
    check(c.csv("GetMotors").get("Vacuum_RPM") == "2100", "vacuum runs while cleaning")

    c.send("Clean Stop")
    check(c.csv("GetMotors").get("Vacuum_RPM") == "0", "vacuum stops on Clean Stop")

    # the button commands the module maps pause/resume/sendToBase onto
    c.send("Clean House")
    c.send("SetButton start")
    check(c.csv("GetMotors").get("Vacuum_RPM") == "0", "SetButton start pauses")
    c.send("SetButton start")
    check(c.csv("GetMotors").get("Vacuum_RPM") == "2100", "SetButton start resumes")
    c.send("SetButton IRhome")
    check(c.csv("GetCharger").get("ExtPwrPresent") == "1", "SetButton IRhome docks")
    check(c.send("SetButton nonsense").startswith("Unknown button"),
          "an unknown button is rejected")

    check(c.send("SetNavigationMode Deep") == "", "SetNavigationMode accepts a mode")
    check(c.csv("GetUsage").get("TotalCleanTime") == "192364", "GetUsage reports totals")

    check("Clean" in c.send("Help"), "Help lists the Clean command")
    check("Spot" in c.send("Help Clean"), "Help Clean documents the subcommands")

    check(c.send("Bogus") == "Unknown Command: Bogus", "unknown commands are reported")

    # battery has to move, otherwise the readings are static noise
    before = int(c.csv("GetCharger")["FuelPercent"])
    c.send("Clean House")
    time.sleep(2.2)
    after = int(c.csv("GetCharger")["FuelPercent"])
    check(after < before, "battery discharges while cleaning (%d -> %d)" % (before, after))
    c.send("Clean Stop")
    c.close()

    # the USB variant has to reproduce error 220
    usb = neato_sim.Server(("127.0.0.1", 0), neato_sim.Handler)
    usb.robot = neato_sim.Robot(usb_attached=True)
    uhost, uport = usb.server_address
    threading.Thread(target=usb.serve_forever, daemon=True).start()

    u = Client(uhost, uport)
    u.send("Clean House")
    check("220 -" in u.send("GetErr"), "USB mode reproduces error 220")
    check(u.csv("GetMotors").get("Vacuum_RPM") == "0", "USB mode does not start cleaning")

    # GetErr Clear has to dismiss it again
    u.send("GetErr Clear")
    check("220 -" not in u.send("GetErr"), "GetErr Clear dismisses the error")
    u.close()

    # --- the undocumented event API ------------------------------------------
    c = Client(host, port)
    key = neato_sim.compute_skey(neato_sim.SIM_SERIAL)
    check(len(key) == 25, "the simulated robot derives a 25 character key")

    check(c.send("SetEvent event UIMGR_EVENT_SMARTAPP_SEND_TO_BASE SKey wrongkey")
          == "Invalid SKey", "a wrong key is refused")

    c.send("Clean House")
    check(c.csv("GetCharger").get("ExtPwrPresent") == "0", "cleaning left the base")
    check(c.send("SetEvent event UIMGR_EVENT_SMARTAPP_SEND_TO_BASE SKey " + key) == "",
          "the send-to-base event is accepted")
    check(c.csv("GetCharger").get("ExtPwrPresent") == "1", "and the robot goes home")

    # GetState has to follow along
    st = c.send("GetState")
    check("Current UI State is:" in st and "Current Robot State is:" in st,
          "GetState reports both states")
    check("ST_M2_Charging_StdBy" in st or "ST_C_Standby" in st,
          "a docked robot reports an idle robot state")

    c.send("SetEvent event UIMGR_EVENT_SMARTAPP_START_HOUSE_CLEANING SKey " + key)
    check("ST_C_Cleaning" in c.send("GetState"), "the cleaning event starts a run")
    check(c.send("SetEvent event UIMGR_EVENT_SMARTAPP_PAUSE_CLEANING SKey " + key) == "",
          "the pause event is accepted")
    check("CLEANINGPAUSED" in c.send("GetState"), "and the robot reports it as paused")
    c.send("SetEvent event UIMGR_EVENT_SMARTAPP_STOP_CLEANING SKey " + key)
    c.close()

    # --- user settings round trip --------------------------------------------
    c = Client(host, port)
    cfg = c.csv("GetUserSettings")
    check(cfg.get("Eco Mode") == "OFF", "eco mode starts off")
    check(cfg.get("Bin Full Detect") == "ON", "bin full detect starts on")
    check("Schedule is Disabled" in c.send("GetUserSettings"),
          "the schedule line has no value column")

    check(c.send("SetUserSettings EcoMode ON") == "", "eco mode can be set")
    check(c.csv("GetUserSettings").get("Eco Mode") == "ON", "and reads back changed")
    check(c.send("SetUserSettings EcoMode maybe").startswith("Value must be"),
          "a bad value is refused")
    check(c.send("SetUserSettings Nonsense ON").startswith("Unknown setting"),
          "an unknown setting is refused")
    c.send("SetUserSettings EcoMode OFF")

    warranty = c.csv("GetWarranty")
    check(warranty.get("CumulativeBatteryCycles") == "05c2",
          "GetWarranty reports the battery cycles as hex")
    c.close()

    print()
    if FAILED:
        print("%d check(s) failed" % len(FAILED))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
