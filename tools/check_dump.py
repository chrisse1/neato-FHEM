#!/usr/bin/env python3
"""
Check for tools/dump_robot.py.

Runs the dump tool against a pseudo terminal that answers like a Botvac, which
exercises the real serial code path -- termios setup, echo suppression, reading
until the Ctrl-Z terminator -- without any hardware. Then repeats the run over
TCP. Run: python3 tools/check_dump.py
"""

import os
import pty
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import neato_sim  # noqa: E402

EOR = b"\x1a"
FAILED = []


def check(cond, label):
    print(("ok   " if cond else "FAIL ") + label)
    if not cond:
        FAILED.append(label)


def serve_pty(master_fd, robot, stop):
    """Answer console commands arriving on the master side of a pty."""
    buf = b""
    os.write(master_fd, b"\r\n" + EOR)
    while not stop.is_set():
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            cmd = line.decode("utf-8", "replace").strip()
            if cmd == "":
                continue
            out = neato_sim.handle_command(robot, cmd)
            payload = cmd + "\r\n"
            if out:
                payload += out.replace("\n", "\r\n") + "\r\n"
            os.write(master_fd, payload.encode("utf-8") + EOR)


def run_dump(extra_args, out_path):
    cmd = [sys.executable, os.path.join(HERE, "dump_robot.py"),
           "--output", out_path, "--timeout", "5"] + extra_args
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    return proc


def main():
    tmp = os.path.join(os.path.dirname(HERE), ".check_dump_tmp")
    os.makedirs(tmp, exist_ok=True)

    # --- serial path, through a pty -----------------------------------------
    master_fd, slave_fd = pty.openpty()
    device = os.ttyname(slave_fd)
    stop = threading.Event()
    robot = neato_sim.Robot()
    thread = threading.Thread(target=serve_pty, args=(master_fd, robot, stop), daemon=True)
    thread.start()

    out_serial = os.path.join(tmp, "serial.txt")
    proc = run_dump(["--device", device], out_serial)
    stop.set()
    os.close(slave_fd)
    try:
        os.close(master_fd)
    except OSError:
        pass

    check(proc.returncode == 0, "dump over a serial device exits cleanly")
    if proc.returncode != 0:
        print(proc.stderr)

    text = open(out_serial).read() if os.path.exists(out_serial) else ""
    check("## Help" in text, "dump contains the command list")
    check("## Help Clean" in text, "dump contains the per-command help")
    check("## GetVersion" in text, "dump contains GetVersion")
    check("## GetCharger" in text, "dump contains GetCharger")
    check("FuelPercent" in text, "GetCharger output survived the serial path")
    check("TIMEOUT" not in text, "no command timed out")
    check("Serial Number,<redacted>" in text, "serial number is redacted by default")
    check("## Help Help" not in text, "the redundant Help Help is skipped")

    # the echo must not end up in the output -- raw mode has to be in effect
    version = text.split("## GetVersion", 1)[1].split("##", 1)[0]
    check("GetVersion\nGetVersion" not in version, "no duplicated command echo")

    # --- TCP path -----------------------------------------------------------
    server = neato_sim.Server(("127.0.0.1", 0), neato_sim.Handler)
    server.robot = neato_sim.Robot()
    host, port = server.server_address
    threading.Thread(target=server.serve_forever, daemon=True).start()
    time.sleep(0.2)

    out_tcp = os.path.join(tmp, "tcp.txt")
    proc = run_dump(["--tcp", "%s:%d" % (host, port), "--no-redact",
                     "--no-help-details"], out_tcp)
    check(proc.returncode == 0, "dump over TCP exits cleanly")

    text = open(out_tcp).read() if os.path.exists(out_tcp) else ""
    check("Serial Number,KSH12345-0000123" in text, "--no-redact keeps the serial number")
    check("## Help Clean" not in text, "--no-help-details skips the detail section")

    print()
    if FAILED:
        print("%d check(s) failed" % len(FAILED))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
