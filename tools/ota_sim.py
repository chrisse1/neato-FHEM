#!/usr/bin/env python3
"""Stand-in for a bridge waiting for an update over the air.

Speaks the device half of the ArduinoOTA protocol, taken from the code the
bridge actually runs (ArduinoOTA.cpp in arduino-esp32) rather than from memory:

  1. a UDP line "<command> <tcp port> <size> <md5>" arrives on the OTA port
  2. the device answers "OK" -- or "AUTH <nonce>" when a password is set
  3. the device opens a TCP connection back to the announced port
  4. for every piece it writes it answers with the number of bytes as decimal
     digits. Not "OK": that comes once, after the last byte
  5. a mismatch in size or checksum ends with an error line instead

--mode makes it fail the way a real one does, so the client can be held against
those cases too.
"""

import argparse
import hashlib
import socket
import sys


def log(text):
    sys.stderr.write("[ota-sim] %s\n" % text)
    sys.stderr.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0,
                    help="OTA port to listen on; 0 picks a free one")
    ap.add_argument("--out", help="write the received image here")
    ap.add_argument("--mode", default="ok",
                    choices=["ok", "auth", "silent", "refuse", "badend"],
                    help="ok: behave; auth: demand a password; silent: ignore "
                         "the invitation; refuse: never connect back; badend: "
                         "report an error after the transfer")
    args = ap.parse_args()

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.bind(("127.0.0.1", args.port))
    port = udp.getsockname()[1]

    # The test needs to know where to send the invitation.
    print(port, flush=True)
    log("listening on udp/%d, mode %s" % (port, args.mode))

    udp.settimeout(30)
    try:
        data, peer = udp.recvfrom(128)
    except socket.timeout:
        log("no invitation arrived")
        return 1

    fields = data.decode("utf-8", "replace").strip().split()
    log("invitation from %s:%d -- %r" % (peer[0], peer[1], fields))

    if len(fields) != 4:
        log("malformed invitation")
        return 1

    command, host_port, size, want_md5 = fields
    host_port = int(host_port)
    size = int(size)

    if args.mode == "silent":
        log("ignoring the invitation on purpose")
        return 0

    if args.mode == "auth":
        udp.sendto(b"AUTH 0123456789abcdef0123456789abcdef", peer)
        log("demanded a password")
        return 0

    udp.sendto(b"OK", peer)

    if args.mode == "refuse":
        log("not connecting back on purpose")
        return 0

    # The device is the one that opens the data connection.
    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp.settimeout(20)
    tcp.connect((peer[0], host_port))
    log("connected back to %s:%d" % (peer[0], host_port))

    received = b""
    while len(received) < size:
        chunk = tcp.recv(1460)
        if not chunk:
            break
        received += chunk
        # What the device really answers: how much it just wrote.
        tcp.sendall(b"%d" % len(chunk))

    got_md5 = hashlib.md5(received).hexdigest()
    log("received %d of %d bytes, md5 %s" % (len(received), size, got_md5))

    if args.out:
        with open(args.out, "wb") as handle:
            handle.write(received)

    if args.mode == "badend":
        tcp.sendall(b"ERROR: bad magic byte")
        log("reported a failure on purpose")
    elif len(received) == size and got_md5 == want_md5:
        tcp.sendall(b"OK")
        log("accepted the image")
    else:
        tcp.sendall(b"ERROR: checksum mismatch")
        log("rejected the image")

    tcp.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
