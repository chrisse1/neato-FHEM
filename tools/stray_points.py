#!/usr/bin/env python3
"""Where a session's stray points come from, and whether the tilt explains them.

    python3 tools/stray_points.py /opt/fhem/www/neato/Staubsauger-....jsonl

A stray is a point in a cell that other beams cross often and almost never
hit -- a point where, by everything else the robot measured, there is nothing.
Those are what stand out when the raw endpoints are drawn.

This exists because the obvious explanation for them turned out to be wrong,
and a negative result that cannot be re-run is only an opinion. Riding up at a
narrow spot tilts the scan plane, and a tilted plane cuts the floor along a
straight line, so the floor comes back shaped exactly like a wall at
h/sin(angle) -- sound geometry, and measured against a full run it explains
nothing. The numbers are in docs/ftui3-map.md. Run this on a newer recording
before believing either way.

Under GPLv2, see LICENSE in the repository root.
"""

import json
import math
import sys
from collections import Counter, defaultdict

CELL = 0.10          # metres
LIDAR_HEIGHT = 0.080 # metres, for the floor distance the tilt would predict


def load(path):
    scans = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line[0] == "#":
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue          # a run caught mid-write ends in half a line
            if "scan" in record:
                scans.append(record["scan"])
    return scans


def between(x0, y0, x1, y1):
    """The cells a beam crosses, endpoint excluded (Bresenham)."""
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    x, y = x0, y0
    while (x, y) != (x1, y1):
        yield (x, y)
        doubled = 2 * err
        if doubled >= dy:
            err += dy
            x += sx
        if doubled <= dx:
            err += dx
            y += sy


def median(values):
    ordered = sorted(values)
    return ordered[len(ordered) // 2] if ordered else 0.0


def quantile(values, share):
    ordered = sorted(values)
    return ordered[int(share * (len(ordered) - 1))] if ordered else 0.0


def correlation(xs, ys):
    if len(xs) < 2:
        return 0.0
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    sx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    sy = math.sqrt(sum((y - my) ** 2 for y in ys))
    if not sx or not sy:
        return 0.0
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / (sx * sy)


def main(path):
    scans = load(path)
    if not scans:
        sys.stderr.write("%s: keine Scans -- ohne mapInterval wird nur die Spur"
                         " aufgezeichnet.\n" % path)
        return 2

    hits, crossed = defaultdict(int), defaultdict(int)
    per_scan = []

    for scan in scans:
        ox = math.floor(scan["x"] / CELL)
        oy = math.floor(scan["y"] / CELL)
        points = []
        for angle, distance in scan.get("pts") or []:
            radians = math.radians(scan["th"] + angle)
            tx = math.floor((scan["x"] + distance / 1000.0 * math.cos(radians)) / CELL)
            ty = math.floor((scan["y"] + distance / 1000.0 * math.sin(radians)) / CELL)
            for cell in between(ox, oy, tx, ty):
                crossed[cell] += 1
            hits[(tx, ty)] += 1
            points.append((tx, ty, angle, distance))
        per_scan.append(points)

    # Contradicted by everything else: crossed often, hit almost never.
    strays = [(i, angle, distance, tx, ty)
              for i, points in enumerate(per_scan)
              for tx, ty, angle, distance in points
              if crossed[(tx, ty)] >= 10 and hits[(tx, ty)] <= 2]

    total = sum(len(p) for p in per_scan)
    print("%s\n%d Scans, %d Punkte" % (path, len(scans), total))
    if not total:
        return 1
    print("%d Irrlaeufer (%.2f %%)\n" % (len(strays), 100 * len(strays) / total))
    if not strays:
        return 0

    # Shape: a tilted scan plane puts the floor on a LINE, so its strays would
    # be one long contiguous arc. Single points are something else entirely.
    by_scan = defaultdict(list)
    for i, angle, _, _, _ in strays:
        by_scan[i].append(angle)
    groups = 0
    for angles in by_scan.values():
        angles.sort()
        groups += 1 + sum(1 for j in range(1, len(angles))
                          if angles[j] - angles[j - 1] > 3)
    print("  Gruppengroesse      %.1f Punkte je zusammenhaengender Gruppe" % (len(strays) / groups))
    print("                      (eine gekippte Ebene ergaebe einen Bogen aus Dutzenden)")

    stray_d = [d for _, _, d, _, _ in strays]
    all_d = [d for points in per_scan for _, _, _, d in points]
    print("  Entfernung          Median %4.0f mm, q90 %4.0f mm"
          % (median(stray_d), quantile(stray_d, 0.9)))
    print("  alle Punkte         Median %4.0f mm, q90 %4.0f mm"
          % (median(all_d), quantile(all_d, 0.9)))

    # A mirror or a glass door would send the same phantom back again and again
    # from the same spot. Scattered cells mean it is not a feature of the flat.
    where = Counter((tx, ty) for _, _, _, tx, ty in strays)
    repeated = sum(v for v in where.values() if v >= 3)
    print("  Wiederkehrend       %d von %d in Zellen, die dreimal oder oefter"
          " getroffen wurden" % (repeated, len(strays)))
    print("                      (%d Zellen betroffen)" % len(where))

    # And the tilt, if the recording carries it (module 0.22.0 and up).
    tilted = [s for s in scans if isinstance(s.get("tilt"), list) and len(s["tilt"]) >= 2]
    print()
    if len(tilted) < len(scans) // 2:
        print("  Keine Neigung aufgezeichnet -- dafuer braucht es Modul 0.22.0 oder neuer.")
        return 0

    # Against the run's OWN resting value, never against zero: the sensor is
    # not calibrated, a level D6 reports -2.33 / -1.20 degrees at 0.951 g.
    base_p = median([s["tilt"][0] for s in tilted])
    base_r = median([s["tilt"][1] for s in tilted])
    print("  Ruhelage dieses Laufs  Pitch %+.2f, Roll %+.2f Grad" % (base_p, base_r))

    devs, shares = [], []
    for i, points in enumerate(per_scan):
        tilt = scans[i].get("tilt")
        if not points or not isinstance(tilt, list) or len(tilt) < 2:
            continue
        dev = math.hypot(tilt[0] - base_p, tilt[1] - base_r)
        devs.append(dev)
        shares.append(len(by_scan.get(i, [])) / len(points))

    print("  Neigung ueber der Ruhelage: Median %.2f, q90 %.2f, max %.2f Grad"
          % (median(devs), quantile(devs, 0.9), max(devs)))
    for angle in (1.0, 2.0, 3.0):
        near = LIDAR_HEIGHT / math.sin(math.radians(angle)) * 1000
        over = sum(1 for d in devs if d > angle)
        print("     ueber %.0f Grad: %3d Scans (%4.1f %%) -- der Boden laege bei %4.0f mm"
              % (angle, over, 100 * over / len(devs), near))

    print()
    print("  Korrelation Neigung <-> Irrlaeufer-Anteil, dieser Lauf: %+.3f"
          % correlation(devs, shares))
    print("  Zum Vergleich, 2026-09-23 ueber 231 Scans:              +0.051")
    print("  Das ist nichts. Die Geometrie stimmt -- der Boden laege wirklich dort --")
    print("  sie kommt in dieser Aufzeichnung nur nicht vor. Kippt das bei mehr")
    print("  Laeufen, gehoert docs/ftui3-map.md nachgezogen.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("python3 tools/stray_points.py <sitzung.jsonl>\n")
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
