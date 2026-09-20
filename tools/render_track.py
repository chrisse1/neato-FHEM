#!/usr/bin/env python3
"""Draw a recorded session: lidar points as the map, the pose samples as the
track the robot drove.

    python3 tools/render_track.py <session.jsonl> [out.svg]

SVG because it needs nothing installed and opens in any browser. FHEM does not
do this -- the module writes the data, whatever draws it decides how.
"""

import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import track_map


def render(path, out):
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

    dots = "".join('<circle cx="%.1f" cy="%.1f" r="1.4"/>' % (sx(x), sy(y))
                   for x, y in points)
    track = " ".join("%.1f,%.1f" % (sx(p["x"]), sy(p["y"])) for p in poses)

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" '
        'viewBox="0 0 %.0f %.0f">\n'
        '<rect width="100%%" height="100%%" fill="#15171a"/>\n'
        '<g fill="#8fb3d9" opacity="0.75">%s</g>\n'
        '<polyline points="%s" fill="none" stroke="#ffb454" stroke-width="2.2" '
        'stroke-linejoin="round"/>\n'
        '<circle cx="%.1f" cy="%.1f" r="6" fill="#5fd35f"/>\n'
        '<circle cx="%.1f" cy="%.1f" r="6" fill="#e05252"/>\n'
        '<text x="12" y="24" fill="#8a9099" font-family="system-ui,sans-serif" '
        'font-size="15">%d points from %d scans, %d poses, %.1f x %.1f m</text>\n'
        '</svg>\n'
        % (width * scale, height * scale, width * scale, height * scale,
           dots, track,
           sx(poses[0]["x"]), sy(poses[0]["y"]),
           sx(poses[-1]["x"]), sy(poses[-1]["y"]),
           len(points), len(scans), len(poses), width, height))

    with open(out, "w") as handle:
        handle.write(svg)

    return len(points), width, height


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    out = argv[2] if len(argv) > 2 else argv[1].rsplit(".", 1)[0] + ".svg"
    count, width, height = render(argv[1], out)
    print("%s: %d points, %.1f x %.1f m" % (out, count, width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
