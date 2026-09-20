#!/usr/bin/env python3
"""Reading a recorded session: the track, and the map the lidar points make.

A session file holds three kinds of line -- a header, one pose per sample, and
one scan per lidar revolution:

    {"device":"Staubsauger","started":"...","module":"0.19.0","unit":"m"}
    {"t":1281.84,"x":0.000,"y":0.000,"th":0.0}
    {"scan":{"x":1.204,"y":0.418,"th":92.0,"speed":5.02,"pose":"Smooth",
             "pts":[[0,1284],[1,1266]]}}
    {"summary":{"points":549,"scans":50,"distance":137.8,...}}

A scan's points are angle in degrees and distance in millimetres, measured from
the pose on the same line. Putting them where they belong is one line of
trigonometry -- see world_points -- but which line it is was not obvious, so it
was measured rather than assumed. See sharpness().
"""

import collections
import json
import math


def load(path):
    """Header, poses and scans of a session file."""
    head, poses, scans = None, [], []

    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            record = json.loads(line)

            if "device" in record:
                head = record
            elif "scan" in record:
                scans.append(record["scan"])
            elif "summary" in record:
                pass
            else:
                poses.append(record)

    return head, poses, scans


def world_points(scan, theta_sign=1, angle_sign=1, offset=0):
    """A scan's points in the coordinates of the run, in metres.

    The robot's heading and the lidar's angle both count counter-clockwise in
    degrees, and the lidar's zero looks where the robot looks:

        x = pose.x + distance * cos(heading + angle)
        y = pose.y + distance * sin(heading + angle)

    The three parameters exist so the alternatives can be tried against real
    data instead of argued about.
    """
    for angle, distance in scan["pts"]:
        radians = math.radians(theta_sign * scan["th"] + angle_sign * angle + offset)
        yield (scan["x"] + distance / 1000.0 * math.cos(radians),
               scan["y"] + distance / 1000.0 * math.sin(radians))


def sharpness(scans, theta_sign=1, angle_sign=1, offset=0, cell=0.10):
    """How well the scans agree with each other, as cells per point.

    Several scans see the same wall from different places. Under the right
    transformation those points land on the same spot, so they occupy few
    cells; under a wrong one they smear out over many. Lower is better.

    This is also how the convention above was established -- and how a first
    attempt was shown NOT to be a convention problem at all: with the pose taken
    from the wheel encoders every transformation scored about the same, which is
    what drifting positions look like. No transformation repairs those.
    """
    grid = collections.Counter()
    total = 0

    for scan in scans:
        for x, y in world_points(scan, theta_sign, angle_sign, offset):
            grid[(round(x / cell), round(y / cell))] += 1
            total += 1

    if not total:
        return None

    return len(grid) / total


def occupancy(scans, cell=0.05):
    """Hits and misses per grid cell, from the endpoints and the rays to them.

    Drawing the endpoints alone throws away most of what a lidar says. A beam
    that stops at 3 m has also established that everything on the way there was
    empty, and that is what turns a sprinkle of points into rooms with edges: a
    cell crossed two hundred times and hit twice is free, not a wall.

    Returns {(ix, iy): [hits, misses]}. The grid is bounded by the flat, not by
    the number of points -- more measurements do not make it bigger, only more
    certain.
    """
    grid = {}

    for scan in scans:
        ox = int(math.floor(scan["x"] / cell))
        oy = int(math.floor(scan["y"] / cell))

        for x, y in world_points(scan):
            tx = int(math.floor(x / cell))
            ty = int(math.floor(y / cell))

            for ix, iy in _line(ox, oy, tx, ty):
                if (ix, iy) == (tx, ty):
                    continue                    # the endpoint is the hit
                entry = grid.setdefault((ix, iy), [0, 0])
                entry[1] += 1

            entry = grid.setdefault((tx, ty), [0, 0])
            entry[0] += 1

    return grid


def _line(x0, y0, x1, y1):
    """The cells a straight beam passes through (Bresenham)."""
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy

    while True:
        yield (x0, y0)
        if x0 == x1 and y0 == y1:
            return
        doubled = 2 * err
        if doubled >= dy:
            err += dy
            x0 += sx
        if doubled <= dx:
            err += dx
            y0 += sy


def occupied(grid, threshold=0.25, seen=2):
    """Cells the evidence calls a wall, and the ones it calls free."""
    walls, free = set(), set()

    for key, (hits, misses) in grid.items():
        total = hits + misses
        if total < seen:
            continue
        if hits / total >= threshold:
            walls.add(key)
        else:
            free.add(key)

    return walls, free


def best_convention(scans, step=15):
    """Every convention, sharpest first. Each entry is (sharpness, *parameters)."""
    results = []

    for theta_sign in (1, -1):
        for angle_sign in (1, -1):
            for offset in range(0, 360, step):
                value = sharpness(scans, theta_sign, angle_sign, offset)
                if value is not None:
                    results.append((value, theta_sign, angle_sign, offset))

    results.sort()
    return results
