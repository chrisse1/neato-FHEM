#!/usr/bin/env python3
"""Draw a recorded session: lidar points as the map, the pose samples as the
track the robot drove.

    python3 tools/render_track.py <session.jsonl> [out.svg] [--points] [--cell 0.05]

By default the lidar is drawn as an occupancy grid: every beam marks the cells
it crossed as free and the cell it ended in as a wall, and what a cell is is
decided by the weight of evidence. --points draws the raw endpoints instead,
which is what the measurements look like before they are counted up.

SVG because it needs nothing installed and opens in any browser. FHEM does not
do this -- the module writes the data, whatever draws it decides how.
"""

import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import track_map


def _runs(cells):
    """Neighbouring cells in a row as one rectangle -- an SVG with 50000 single
    squares is a slow page for no gain."""
    rows = {}
    for ix, iy in cells:
        rows.setdefault(iy, []).append(ix)

    for iy, xs in sorted(rows.items()):
        xs.sort()
        start = prev = xs[0]
        for ix in xs[1:]:
            if ix == prev + 1:
                prev = ix
                continue
            yield (start, iy, prev - start + 1)
            start = prev = ix
        yield (start, iy, prev - start + 1)


def render(path, out, grid=True, cell=0.05):
    _head, poses, scans = track_map.load(path)

    if not poses:
        raise SystemExit("no poses in %s -- nothing to draw" % path)

    points = [p for scan in scans for p in track_map.world_points(scan)]

    xs = [x for x, _ in points] + [p["x"] for p in poses]
    ys = [y for _, y in points] + [p["y"] for p in poses]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)

    pad = 0.4
    width = (maxx - minx) + 2 * pad
    height = (maxy - miny) + 2 * pad
    scale = 900.0 / max(width, height)

    def sx(x):
        return (x - minx + pad) * scale

    def sy(y):
        return (maxy - y + pad) * scale      # SVG counts y downwards

    if grid:
        counts = track_map.occupancy(scans, cell)
        walls, free = track_map.occupied(counts)

        def rects(cells, colour):
            out = []
            for ix, iy, run in _runs(cells):
                out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" '
                           'fill="%s"/>'
                           % (sx(ix * cell), sy((iy + 1) * cell),
                              run * cell * scale + 0.5, cell * scale + 0.5,
                              colour))
            return "".join(out)

        body = rects(free, "#22262b") + rects(walls, "#9ec9f0")
        what = "%d wall cells, %d free" % (len(walls), len(free))
    else:
        body = ('<g fill="#8fb3d9" opacity="0.75">%s</g>'
                % "".join('<circle cx="%.1f" cy="%.1f" r="1.4"/>' % (sx(x), sy(y))
                          for x, y in points))
        what = "%d points" % len(points)

    track = " ".join("%.1f,%.1f" % (sx(p["x"]), sy(p["y"])) for p in poses)

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" '
        'viewBox="0 0 %.0f %.0f">\n'
        '<rect width="100%%" height="100%%" fill="#15171a"/>\n'
        '%s\n'
        '<polyline points="%s" fill="none" stroke="#ffb454" stroke-width="2.2" '
        'stroke-linejoin="round" opacity="0.9"/>\n'
        '<circle cx="%.1f" cy="%.1f" r="6" fill="#5fd35f"/>\n'
        '<circle cx="%.1f" cy="%.1f" r="6" fill="#e05252"/>\n'
        '<text x="12" y="24" fill="#8a9099" font-family="system-ui,sans-serif" '
        'font-size="15">%s from %d scans, %d poses, %.1f x %.1f m</text>\n'
        '</svg>\n'
        % (width * scale, height * scale, width * scale, height * scale,
           body, track,
           sx(poses[0]["x"]), sy(poses[0]["y"]),
           sx(poses[-1]["x"]), sy(poses[-1]["y"]),
           what, len(scans), len(poses), width, height))

    with open(out, "w") as handle:
        handle.write(svg)

    return len(points), width, height


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = [a for a in argv[1:] if a.startswith("--")]

    if not args:
        sys.stderr.write(__doc__)
        return 2

    cell = 0.05
    if "--cell" in flags:
        cell = float(argv[argv.index("--cell") + 1])
        args = [a for a in args if a != str(cell)]

    out = args[1] if len(args) > 1 else args[0].rsplit(".", 1)[0] + ".svg"
    count, width, height = render(args[0], out,
                                  grid="--points" not in flags, cell=cell)
    print("%s: %d points, %.1f x %.1f m" % (out, count, width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
