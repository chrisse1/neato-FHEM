#!/usr/bin/env python3
"""Checks for the partition table reader.

The offset it produces decides where the credentials block is written. Getting
it wrong means writing into a neighbouring partition, so the parser is pinned
down against a table built here rather than against whatever CI happens to
produce.
"""

import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import partition_offset

FAILED = []


def check(ok, what):
    print("%s   %s" % ("ok  " if ok else "FAIL", what))
    if not ok:
        FAILED.append(what)


def entry(label, ptype, subtype, offset, size):
    """One table entry, byte for byte as it sits on flash.

    The magic is written as the literal bytes ESP-IDF puts there, not taken from
    the module under test: the first version of this file reused the module's
    constant, so both had the byte order wrong and the tests passed anyway.
    """
    return (b"\xaa\x50"
            + struct.pack("<BBII", ptype, subtype, offset, size)
            + label.encode().ljust(16, b"\0")
            + struct.pack("<I", 0))


def main():
    table = (entry("nvs", 1, 2, 0x9000, 0x5000)
             + entry("otadata", 1, 0, 0xe000, 0x2000)
             + entry("app0", 0, 0x10, 0x10000, 0x1e0000)
             + entry("app1", 0, 0x11, 0x1f0000, 0x1e0000)
             + entry("spiffs", 1, 0x82, 0x3d0000, 0x20000))

    check(partition_offset.find(table, "spiffs") == (0x3d0000, 0x20000),
          "the storage partition is found by name")
    check(partition_offset.find(table, "app0")[0] == 0x10000,
          "and so is any other")
    check(partition_offset.find(table, "nosuch") is None,
          "a name that is not there gives nothing")

    # Real tables are padded to a flash sector with 0xFF, and the reader has to
    # stop at the padding instead of reading it as entries.
    padded = table + b"\xff" * (0x1000 - len(table))
    check(partition_offset.find(padded, "spiffs") == (0x3d0000, 0x20000),
          "padding after the table is not mistaken for entries")
    check(partition_offset.find(padded, "nosuch") is None,
          "and does not turn into a match either")

    # The label list exists because the schemes disagree; both spellings have
    # to resolve to the same partition.
    littlefs = (entry("nvs", 1, 2, 0x9000, 0x5000)
                + entry("app0", 0, 0x10, 0x10000, 0x1e0000)
                + entry("littlefs", 1, 0x83, 0x3d0000, 0x20000))
    check(partition_offset.find(littlefs, "spiffs") is None,
          "a scheme without spiffs does not pretend to have one")
    check(partition_offset.find(littlefs, "littlefs")[0] == 0x3d0000,
          "and is found under the name it does use")

    # Every partition is listed, which is what makes a wrong guess visible
    # instead of merely fatal.
    listed = [row[0] for row in partition_offset.entries(table)]
    check(listed == ["nvs", "otadata", "app0", "app1", "spiffs"],
          "the whole table can be listed, in order")

    # A truncated download must not be read as a valid table.
    check(partition_offset.find(table[:20], "nvs") is None,
          "a truncated table yields nothing")

    print()
    if FAILED:
        print("%d check(s) failed" % len(FAILED))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
