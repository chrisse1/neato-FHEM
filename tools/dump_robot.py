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
import fcntl
import os
import re
import select
import socket
import struct
import sys
import termios
import time

EOR = b"\x1a"  # the console terminates every response with Ctrl-Z

# How a command line is terminated. Which one the console wants depends on the
# firmware, so "auto" probes all three before giving up.
EOL_CHOICES = {"lf": "\n", "cr": "\r", "crlf": "\r\n"}

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

        # Many CDC-ACM devices stay mute until the host asserts DTR -- the
        # firmware treats it as "a terminal is attached". pyserial does this
        # for you; doing it by hand means doing this too.
        self.modem_error = None
        try:
            fcntl.ioctl(self.fd, termios.TIOCMBIS,
                        struct.pack("I", termios.TIOCM_DTR | termios.TIOCM_RTS))
        except OSError as exc:
            self.modem_error = exc  # ptys and some drivers do not support it

    def modem_status(self):
        """Return the modem control lines as a dict, or None if unsupported."""
        try:
            packed = fcntl.ioctl(self.fd, termios.TIOCMGET, struct.pack("I", 0))
        except OSError:
            return None
        bits = struct.unpack("I", packed)[0]
        return {
            "DTR": bool(bits & termios.TIOCM_DTR),
            "RTS": bool(bits & termios.TIOCM_RTS),
            "CTS": bool(bits & termios.TIOCM_CTS),
            "DSR": bool(bits & termios.TIOCM_DSR),
            "DCD": bool(bits & termios.TIOCM_CAR),
        }

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
    def __init__(self, transport, timeout=8.0, eol="\n"):
        self.t = transport
        self.timeout = timeout
        self.eol = eol
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
        self.t.write((cmd + self.eol).encode("utf-8"))

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


    def probe_eol(self, candidates=("lf", "cr", "crlf"), timeout=4.0):
        """Find a line ending the console actually answers to.

        Returns the winning key, or None if the robot stayed silent for all of
        them -- which points at the wiring, the port or a sleeping robot rather
        than at the protocol.
        """
        for key in candidates:
            self.eol = EOL_CHOICES[key]
            self.drain(0.2)
            self.t.write(("GetVersion" + self.eol).encode("utf-8"))

            deadline = time.monotonic() + timeout
            got = b""
            while time.monotonic() < deadline:
                chunk = self.t.read_ready(0.3)
                if chunk:
                    got += chunk
                    if EOR in got:
                        break
            if got.strip():
                self.buf = b""
                return key

        self.buf = b""
        return None


def hexdump(data, limit=512):
    """Readable dump of whatever came back, for the diagnose report."""
    data = data[:limit]
    lines = []
    for off in range(0, len(data), 16):
        chunk = data[off:off + 16]
        hexpart = " ".join("%02x" % b for b in chunk)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append("%04x  %-47s  %s" % (off, hexpart, text))
    return "\n".join(lines) if lines else "(nothing received)"


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


def port_holders(device):
    """Which processes have this device open? Answers the 'FHEM has it' case."""
    holders = []
    target = os.path.realpath(device)
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return holders

    mypid = str(os.getpid())
    for pid in pids:
        if pid == mypid:
            continue  # our own open fd is not a conflict
        fddir = "/proc/%s/fd" % pid
        try:
            for fd in os.listdir(fddir):
                try:
                    if os.path.realpath(os.path.join(fddir, fd)) == target:
                        try:
                            with open("/proc/%s/comm" % pid) as fh:
                                name = fh.read().strip()
                        except OSError:
                            name = "?"
                        holders.append("%s (pid %s)" % (name, pid))
                        break
                except OSError:
                    continue
        except OSError:
            continue  # not our process, or it went away
    return holders


def usb_info(device):
    """Vendor, product and driver of the USB device behind a tty."""
    name = os.path.basename(device)
    base = "/sys/class/tty/%s/device" % name
    if not os.path.exists(base):
        return {}

    info = {}
    path = os.path.realpath(base)
    for _ in range(6):  # walk up to the USB device node
        for key in ("idVendor", "idProduct", "product", "manufacturer"):
            f = os.path.join(path, key)
            if key not in info and os.path.exists(f):
                try:
                    with open(f) as fh:
                        info[key] = fh.read().strip()
                except OSError:
                    pass
        if "idVendor" in info:
            break
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return info


def diagnose(args):
    """Collect everything needed to tell why the robot stays silent."""
    out = []

    def say(line=""):
        print(line)
        out.append(line)

    say("# Neato serial diagnosis")
    say()
    say("date: %s" % time.strftime("%Y-%m-%d %H:%M:%S"))

    if args.tcp:
        say("target: %s (TCP)" % args.tcp)
    else:
        device = args.device
        say("target: %s" % device)
        say()
        say("## Device")
        if not os.path.exists(device):
            say("MISSING: %s does not exist." % device)
            candidates = sorted(
                [os.path.join("/dev", d) for d in os.listdir("/dev")
                 if d.startswith(("ttyACM", "ttyUSB"))])
            say("serial devices present: %s"
                % (", ".join(candidates) if candidates else "none"))
            say()
            say("The robot's USB port only enumerates while the robot is awake.")
            say("Wake it with a button press and check 'dmesg | tail'.")
            _write_report(args, out)
            return 1

        st = os.stat(device)
        say("mode: %o  uid: %d  gid: %d" % (st.st_mode & 0o777, st.st_uid, st.st_gid))
        say("readable: %s  writable: %s"
            % (os.access(device, os.R_OK), os.access(device, os.W_OK)))
        say("current user: uid=%d gid=%d groups=%s"
            % (os.getuid(), os.getgid(), ",".join(str(g) for g in os.getgroups())))

        holders = port_holders(device)
        say("opened by: %s" % (", ".join(holders) if holders else
                               "nobody visible to this user"))
        if holders:
            say("NOTE: another process holds the port. FHEM will keep it open "
                "once the device is defined -- delete or disable it first.")

        info = usb_info(device)
        if info:
            say("usb: %s:%s %s %s" % (info.get("idVendor", "?"),
                                      info.get("idProduct", "?"),
                                      info.get("manufacturer", ""),
                                      info.get("product", "")))

    say()
    say("## Connection")
    try:
        if args.tcp:
            transport = TcpTransport(args.tcp)
        else:
            transport = SerialTransport(args.device, args.baud)
    except Exception as exc:
        say("FAILED to open: %s: %s" % (type(exc).__name__, exc))
        _write_report(args, out)
        return 1
    say("opened successfully")

    try:
        if isinstance(transport, SerialTransport):
            if transport.modem_error:
                say("DTR/RTS could not be set: %s" % transport.modem_error)
            else:
                say("DTR/RTS asserted")
            status = transport.modem_status()
            if status:
                say("modem lines: %s"
                    % " ".join("%s=%d" % (k, v) for k, v in sorted(status.items())))

        console = Console(transport, timeout=args.timeout)

        say()
        say("## Passive listen (5s, no command sent)")
        deadline = time.monotonic() + 5.0
        passive = b""
        while time.monotonic() < deadline:
            chunk = transport.read_ready(0.5)
            if chunk:
                passive += chunk
        say(hexdump(passive))

        say()
        say("## Line ending probe")
        results = {}
        for key in ("lf", "cr", "crlf"):
            console.eol = EOL_CHOICES[key]
            console.drain(0.3)
            transport.write(("GetVersion" + console.eol).encode("utf-8"))
            deadline = time.monotonic() + 4.0
            got = b""
            while time.monotonic() < deadline:
                chunk = transport.read_ready(0.3)
                if chunk:
                    got += chunk
                    if EOR in got:
                        break
            results[key] = got
            say()
            say("### %s (%s)" % (key, repr(EOL_CHOICES[key])))
            say("%d bytes, terminator seen: %s" % (len(got), EOR in got))
            say(hexdump(got))

        say()
        say("## Verdict")
        answered = [k for k, v in results.items() if v.strip()]
        if answered:
            say("The console answers with: %s" % ", ".join(answered))
            say("Re-run the dump with --eol %s" % answered[0])
        else:
            say("No answer to any line ending.")
            say("Most likely, in this order:")
            say("  1. The robot is asleep. Press a button, take it off the base "
                "and put it back, then re-run immediately.")
            say("  2. Wrong port -- try the other ttyACM*/ttyUSB* devices listed above.")
            say("  3. The port is held by another process (see above).")
            say("  4. The USB cable is charge-only. Try a known-good data cable.")
    finally:
        transport.close()

    _write_report(args, out)
    return 0


def _write_report(args, lines):
    path = args.output if args.output != "neato-dump.txt" else "neato-diagnose.txt"
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\nwrote %s" % path)


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
    ap.add_argument("--eol", choices=["auto"] + sorted(EOL_CHOICES), default="auto",
                    help="line ending sent after each command (default: probe)")
    ap.add_argument("--diagnose", action="store_true",
                    help="report why the robot stays silent instead of dumping")
    args = ap.parse_args()

    if args.diagnose:
        return diagnose(args)

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

        if args.eol == "auto":
            print("probing the line ending ...")
            console.eol = EOL_CHOICES["lf"]
            console.send("wake-up", timeout=3.0)
            found = console.probe_eol()
            if found is None:
                print("\nThe robot does not answer to any line ending.\n"
                      "Run the same command with --diagnose to find out why:\n"
                      "  python3 %s %s --diagnose"
                      % (os.path.basename(__file__),
                         "--device " + args.device if args.device else "--tcp " + args.tcp),
                      file=sys.stderr)
                return 1
            print("console answers to %s (%s)" % (found, repr(EOL_CHOICES[found])))
        else:
            console.eol = EOL_CHOICES[args.eol]
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
