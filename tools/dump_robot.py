#!/usr/bin/env python3
"""
Reads a complete reference of a Neato Botvac's serial console.

Asks the robot for its command list, then asks it for the help text of every
command it named, plus the output of the harmless Get* commands. The result is
one text file that documents exactly what *your* firmware understands -- which
is what the missing entries in docs/serial-commands.md need.

    python3 tools/dump_robot.py --device /dev/ttyACM0
    python3 tools/dump_robot.py --tcp 192.168.1.42:23     # via a WiFi bridge
    python3 tools/dump_robot.py --tcp 127.0.0.1:8888      # against neato_sim.py

Only reads. The script sends Help and Get* commands and nothing else -- no
TestMode, no motor commands, no settings changes, nothing that could leave the
robot in a state it was not in before.

Needs nothing but a standard Python 3; the serial port is configured through
the termios module from the standard library, so pyserial is not required.
"""

import argparse
import os
import re
import select
import socket
import sys
import termios
import time

EOR = b"\x1a"  # the console terminates every response with Ctrl-Z

# Commands that only report. Anything that writes, moves or reconfigures is
# deliberately absent -- this script must not change the robot.
SAFE_GET_COMMANDS = [
    "GetVersion",
    "GetCharger",
    "GetErr",
    "GetMotors",
    "GetAnalogSensors",
    "GetDigitalSensors",
    "GetButtons",
    "GetAccel",
    "GetCalInfo",
    "GetSchedule",
    "GetTime",
    "GetUserSettings",
    "GetWarranty",
]


class Transport:
    """Common interface for the serial port and the TCP bridge."""

    def write(self, data):
        raise NotImplementedError

    def read_ready(self, timeout):
        raise NotImplementedError

    def close(self):
        raise NotImplementedError


class SerialTransport(Transport):
    """Raw 115200 8N1 access to a CDC-ACM port, using only the stdlib."""

    def __init__(self, device, baud=115200):
        self.fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

        speed = getattr(termios, "B%d" % baud)
        attrs = termios.tcgetattr(self.fd)
        iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs

        # raw mode: no translation, no echo, no flow control
        iflag &= ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK
                   | termios.ISTRIP | termios.INLCR | termios.IGNCR
                   | termios.ICRNL | termios.IXON | termios.IXOFF | termios.IXANY)
        oflag &= ~termios.OPOST
        lflag &= ~(termios.ECHO | termios.ECHONL | termios.ICANON
                   | termios.ISIG | termios.IEXTEN)
        cflag &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)
        cflag |= termios.CS8 | termios.CREAD | termios.CLOCAL

        cc[termios.VMIN] = 0
        cc[termios.VTIME] = 0

        termios.tcsetattr(self.fd, termios.TCSANOW,
                          [iflag, oflag, cflag, lflag, speed, speed, cc])
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def write(self, data):
        os.write(self.fd, data)

    def read_ready(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return b""
        try:
            return os.read(self.fd, 4096)
        except BlockingIOError:
            return b""

    def close(self):
        os.close(self.fd)


class TcpTransport(Transport):
    def __init__(self, hostport):
        host, port = hostport.rsplit(":", 1)
        self.sock = socket.create_connection((host, int(port)), timeout=10)

    def write(self, data):
        self.sock.sendall(data)

    def read_ready(self, timeout):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return b""
        return self.sock.recv(4096)

    def close(self):
        self.sock.close()


class Console:
    def __init__(self, transport, timeout=8.0, verbose=True):
        self.t = transport
        self.timeout = timeout
        self.verbose = verbose
        self.buf = b""

    def drain(self, seconds=0.5):
        """Throw away whatever is already in flight."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.t.read_ready(0.1)
        self.buf = b""

    def send(self, cmd, timeout=None):
        """Send one command, return its output without echo and terminator."""
        timeout = timeout if timeout is not None else self.timeout
        self.t.write((cmd + "\n").encode("utf-8"))

        deadline = time.monotonic() + timeout
        while EOR not in self.buf:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                # return what we have, flagged, instead of losing it
                partial = self.buf.decode("utf-8", "replace")
                self.buf = b""
                return "<<< TIMEOUT after %.0fs >>>\n%s" % (timeout, partial.strip())
            chunk = self.t.read_ready(min(remaining, 0.5))
            if chunk:
                self.buf += chunk

        raw, self.buf = self.buf.split(EOR, 1)
        text = raw.decode("utf-8", "replace").lstrip("\r\n")

        # the console echoes the command back before its output
        if text.lower().startswith(cmd.lower()):
            text = text[len(cmd):].lstrip("\r\n")

        return text.strip()


def discover_commands(help_text):
    """Pull the command names out of the robot's own help output."""
    names = []
    for line in help_text.splitlines():
        m = re.match(r"^\s*([A-Za-z][A-Za-z0-9_]*)\s+-\s+", line)
        if m:
            name = m.group(1)
            if name not in names:
                names.append(name)
    return names


def redact(text):
    """Mask the robot's serial numbers so the dump can be shared."""
    text = re.sub(r"(?im)^(\s*(?:Serial\s*Number|LDS\s*Serial)\s*,)[^,\r\n]*",
                  r"\1<redacted>", text)
    return text


def main():
    ap = argparse.ArgumentParser(description="Dump a Neato Botvac's serial console")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--device", help="serial device, e.g. /dev/ttyACM0")
    src.add_argument("--tcp", help="host:port of a serial bridge")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--timeout", type=float, default=8.0)
    ap.add_argument("--output", default="neato-dump.txt")
    ap.add_argument("--no-redact", action="store_true",
                    help="keep serial numbers in the dump")
    ap.add_argument("--no-help-details", action="store_true",
                    help="skip the per-command help texts (much faster)")
    args = ap.parse_args()

    if args.device:
        print("opening %s at %d baud" % (args.device, args.baud))
        transport = SerialTransport(args.device, args.baud)
        source = args.device
    else:
        print("connecting to %s" % args.tcp)
        transport = TcpTransport(args.tcp)
        source = args.tcp

    console = Console(transport, timeout=args.timeout)
    sections = []

    try:
        # a sleeping console swallows the first command it receives
        console.drain()
        console.send("wake-up", timeout=3.0)
        console.drain(0.3)

        print("asking for the command list ...")
        help_text = console.send("Help", timeout=15.0)
        sections.append(("Help", help_text))

        commands = discover_commands(help_text)
        print("robot reports %d commands" % len(commands))

        if not commands:
            print("WARNING: no commands parsed -- is the robot awake and is this "
                  "really its console?", file=sys.stderr)

        if not args.no_help_details:
            for name in commands:
                if name.lower() == "help":
                    continue  # would just repeat the list we already have
                print("  Help %s" % name)
                sections.append(("Help " + name, console.send("Help " + name)))

        for cmd in SAFE_GET_COMMANDS:
            # only ask for what this firmware actually offers
            if commands and cmd not in commands:
                continue
            print("  %s" % cmd)
            sections.append((cmd, console.send(cmd)))

    finally:
        transport.close()

    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    out = ["# Neato console dump",
           "",
           "source: %s" % source,
           "date: %s" % stamp,
           ""]
    for title, body in sections:
        out.append("")
        out.append("## " + title)
        out.append("```")
        out.append(body if body else "(no output)")
        out.append("```")

    text = "\n".join(out) + "\n"
    if not args.no_redact:
        text = redact(text)

    with open(args.output, "w") as fh:
        fh.write(text)

    print("\nwrote %s (%d sections, %d bytes)"
          % (args.output, len(sections), len(text)))
    print("send this file back and the missing commands go into the module.")


if __name__ == "__main__":
    main()
