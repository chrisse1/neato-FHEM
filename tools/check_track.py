#!/usr/bin/env python3
"""Checks for the session format and the coordinate convention.

The fixture is a thinned but otherwise untouched recording from a BotVac D6.
Its scans are what make the convention checkable at all: the test does not
assert that the formula looks right, it asserts that this formula and no other
makes points from different scans agree.
"""

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import track_map

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "docs", "reference-track-botvac-d6.jsonl")
FAILED = []


def check(ok, what):
    print("%s   %s" % ("ok  " if ok else "FAIL", what))
    if not ok:
        FAILED.append(what)


def main():
    head, poses, scans = track_map.load(FIXTURE)

    check(head is not None and head.get("unit") == "m",
          "the header states the unit, so nobody has to guess")
    check(len(poses) > 20, "the fixture holds poses")
    check(len(scans) == 10, "and ten scans")
    check(all(s.get("pose") == "Smooth" for s in scans),
          "recorded from the corrected position, and it says so")

    # Every scan carries its own pose; points without one cannot be placed.
    check(all({"x", "y", "th", "pts"} <= set(s) for s in scans),
          "every scan carries the pose it was measured from")

    # The distances are already filtered when they are written.
    distances = [d for s in scans for _a, d in s["pts"]]
    check(min(distances) > 0, "no zero-distance readings survive into the file")
    check(max(distances) <= 6000, "and nothing beyond the lidar's reach")

    # The convention, measured rather than asserted.
    ranked = track_map.best_convention(scans)
    best = ranked[0]
    margin = (ranked[1][0] - best[0]) / best[0]

    check(best[1:] == (1, 1, 0),
          "the documented convention is the sharpest of all 96 tried")
    check(margin > 0.10,
          "and it wins by %.0f %%, not by a hair" % (margin * 100))

    # Its mirror is the runner-up, which is why the margin matters: mirroring a
    # roughly symmetric flat looks almost as tidy.
    mirror = [r for r in ranked if r[1:] == (-1, -1, 180)]
    check(mirror and mirror[0][0] > best[0],
          "the mirrored convention scores worse, as it must")

    # A scan with nothing in it must not bring the measurement down.
    check(track_map.sharpness([]) is None, "no scans yields no number, not a zero")

    # --- the grid, on a scan whose answer is known by construction ----------
    # One beam, two metres straight ahead from the origin. Everything it
    # crossed is free, and only where it stopped is there a wall.
    one = [{"x": 0.0, "y": 0.0, "th": 0.0, "pts": [[0, 2000]]}]
    grid = track_map.occupancy(one, cell=0.10)

    check(grid.get((20, 0), [0, 0])[0] == 1, "the beam's end is counted as a hit")
    check(grid.get((10, 0), [0, 0])[1] == 1, "and halfway there as a miss")
    check(grid.get((20, 0), [0, 0])[1] == 0, "the endpoint is not also a miss")
    check((25, 0) not in grid, "nothing is claimed beyond where the beam stopped")

    walls, free = track_map.occupied(grid, seen=1)
    check(walls == {(20, 0)}, "so exactly one cell counts as a wall")
    check((10, 0) in free, "and the way there counts as free")

    # Evidence, not the last word: a cell crossed often and hit once is free.
    crossing = [{"x": 0.0, "y": 0.0, "th": 0.0, "pts": [[0, 2000]]}] * 20
    stopping = [{"x": 0.0, "y": 0.0, "th": 0.0, "pts": [[0, 1000]]}]
    mixed = track_map.occupancy(crossing + stopping, cell=0.10)
    walls, free = track_map.occupied(mixed)
    check((10, 0) in free and (10, 0) not in walls,
          "a cell crossed twenty times and hit once is free, not a wall")
    check((20, 0) in walls, "while the wall behind it stays a wall")

    # The grid is bounded by the flat, not by how much was measured.
    once = track_map.occupancy(scans, cell=0.10)
    twice = track_map.occupancy(scans + scans, cell=0.10)
    check(set(once) == set(twice),
          "measuring twice as much does not make the grid bigger")
    check(sum(sum(v) for v in twice.values()) == 2 * sum(sum(v) for v in once.values()),
          "only more certain")

    # And the renderer runs end to end.
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "map.svg")
        rc = subprocess.call([sys.executable,
                              os.path.join(os.path.dirname(__file__), "render_track.py"),
                              FIXTURE, out], stdout=subprocess.DEVNULL)
        check(rc == 0, "the renderer runs")
        check(os.path.exists(out) and os.path.getsize(out) > 1000,
              "and produces an SVG with something in it")
        with open(out) as handle:
            svg = handle.read()
        check(svg.startswith("<svg") and svg.rstrip().endswith("</svg>"),
              "which is well-formed at both ends")

    print()
    if FAILED:
        print("%d check(s) failed" % len(FAILED))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
