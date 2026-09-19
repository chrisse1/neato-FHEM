#!/usr/bin/env python3
"""Print the flash offset of a partition, read from a partition table image.

The flashing tool has to write the credentials block to the same partition the
firmware reads it from. Taking the offset from the very table that ships inside
the image keeps the two from drifting apart -- a hard-coded offset would be
right only for as long as nobody changes the partition scheme.
"""

import struct
import sys

MAGIC = 0xAA50
ENTRY_SIZE = 32


def find(table, label):
    """Return (offset, size) of the named partition, or None."""
    for pos in range(0, len(table), ENTRY_SIZE):
        entry = table[pos:pos + ENTRY_SIZE]
        if len(entry) < ENTRY_SIZE:
            break
        magic, _type, _subtype, offset, size = struct.unpack("<HBBII", entry[:12])
        if magic != MAGIC:
            break          # end of the table, or padding
        name = entry[12:28].split(b"\0")[0].decode("utf-8", "replace")
        if name == label:
            return offset, size
    return None


def entries(table):
    """Every partition in the table, as (label, type, subtype, offset, size)."""
    out = []
    for pos in range(0, len(table), ENTRY_SIZE):
        entry = table[pos:pos + ENTRY_SIZE]
        if len(entry) < ENTRY_SIZE:
            break
        magic, ptype, subtype, offset, size = struct.unpack("<HBBII", entry[:12])
        if magic != MAGIC:
            break
        label = entry[12:28].split(b"\0")[0].decode("utf-8", "replace")
        out.append((label, ptype, subtype, offset, size))
    return out


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: %s <partitions.bin> <label>[,<label>...]\n"
                         % argv[0])
        return 2

    with open(argv[1], "rb") as handle:
        table = handle.read()

    if argv[2] == "--list":
        for label, ptype, subtype, offset, size in entries(table):
            print("%-16s type %d subtype 0x%02x at 0x%x, %d bytes"
                  % (label, ptype, subtype, offset, size))
        return 0

    # Several names are accepted because the stock schemes do not agree on one:
    # the storage partition is spiffs here, littlefs or storage there. Guessing
    # a single name is how this failed the first time round.
    for label in argv[2].split(","):
        found = find(table, label.strip())
        if found is not None:
            print("0x%x" % found[0])
            return 0

    sys.stderr.write("none of '%s' in %s. The table holds:\n" % (argv[2], argv[1]))
    for label, ptype, subtype, offset, size in entries(table):
        sys.stderr.write("  %-16s type %d subtype 0x%02x at 0x%x, %d bytes\n"
                         % (label, ptype, subtype, offset, size))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
