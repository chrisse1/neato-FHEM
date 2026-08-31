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
    check(version.get("Serial Number") == "KSH12345-0000123", "GetVersion carries the serial number")
    check("MainBoard Software" in version, "GetVersion carries the firmware version")

    charger = c.csv("GetCharger")
    check(charger.get("FuelPercent", "").isdigit(), "FuelPercent is numeric")
    check(charger.get("ExtPwrPresent") == "1", "robot starts docked")

    check(c.csv("GetMotors").get("Vacuum_RPM") == "0", "vacuum is off while docked")
    check(c.send("GetErr") == "", "no error while idle")

    c.send("Clean House")
    check(c.csv("GetCharger").get("ExtPwrPresent") == "0", "cleaning leaves the base")
    check(c.csv("GetMotors").get("Vacuum_RPM") == "2100", "vacuum runs while cleaning")

    c.send("Clean Stop")
    check(c.csv("GetMotors").get("Vacuum_RPM") == "0", "vacuum stops on Clean Stop")

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
    check(u.send("GetErr").startswith("220 - "), "USB mode reproduces error 220")
    check(u.csv("GetMotors").get("Vacuum_RPM") == "0", "USB mode does not start cleaning")
    u.close()

    print()
    if FAILED:
        print("%d check(s) failed" % len(FAILED))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
