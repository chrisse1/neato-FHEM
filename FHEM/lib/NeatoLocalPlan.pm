##############################################################################
# NeatoLocalPlan.pm - one floor plan out of several cleaning runs.
#
# A single run is the map of that run, not of the flat: its own origin, its own
# north, and only the rooms the robot got into that day. Laid on top of each
# other, several runs can do two things no single one can - fill in the walls
# that were missing, and let every cell be voted on. What three runs out of
# four call a wall is a wall; what one calls a wall while the others looked at
# the same spot and saw floor was the laundry rack.
#
# This is the second implementation of a procedure whose first is in
# JavaScript, in the FTUI component repository (fhem-ftui-components-neatomaps,
# www/ftui/components/neato/neato-plan.js). The file format and the procedure
# are written down in that repository's docs/plan-format.md, and
# tools/check-plan.mjs there decides whether the two agree - not an opinion.
# tools/check_plan.pl here runs the same comparison without node.
#
# Deliberately different from the JavaScript in one place: that one guesses the
# rotation from the dominant wall direction and tries four candidates, because
# it has to run in a browser. This one sweeps all of them in three degree
# steps. It is thirty times as much work and it happens in a forked process,
# where the seconds cost nothing - and it drops the whole line fitting pipeline
# that the shortcut needs. docs/plan-format.md says as much, and a test over
# there holds the two to the same answer.
#
# No FHEM in here on purpose: this is arithmetic, and arithmetic is easier to
# trust when it can be run from a plain perl script.
#
# Copyright and license: see LICENSE (GPLv2) in the repository root.
##############################################################################

package NeatoLocalPlan;

use strict;
use warnings;

use POSIX qw(ceil floor);
use JSON::PP;

our $VERSION = "0.1.0";

# The numbers the procedure runs on. Every one of them is in docs/plan-format.md
# of the component repository; changing one here without changing it there
# breaks the seam between the two.
our %DEFAULTS = (
    cell      => 0.10,   # grid, in metres
    threshold => 0.25,   # hits / (hits + passes) from which a cell is a wall
    minSeen   => 2,      # fewer observations than this decide nothing

    # How far apart two cells may be and still mean the same wall. One cell: a
    # wall ten centimetres over is the same wall. This belongs in the VOTE, not
    # in the set of cells -- counting the widened sets turns 1800 wall cells
    # into 5000 and gives the flat metre-thick walls.
    slack     => 1,

    step      => 0.4,    # the translation sweep, in metres
    margin    => 5,      # how far around the frame it looks, in metres
    sweep     => 3,      # the rotation sweep, in degrees
    accept    => 0.45,   # below this a run does not belong in this plan

    # Refinement after the sweep, coarse to fine: degrees and metres per stage.
    stages    => [ [ 1.2, 0.15 ], [ 0.3, 0.05 ], [ 0.1, 0.02 ] ],

    # Laying the revolutions of one run on top of each other, before anything
    # else. A run whose own walls are a bundle of parallel strokes cannot be
    # matched against anything.
    alignCell   => 0.10,
    alignRounds => 3,
    alignReach  => 0.5,  # total travel allowed per revolution, in metres
    alignSample => 130,  # points per revolution used for matching
);

# JavaScript's Math.round, which rounds half towards plus infinity and is NOT
# perl's int($x + 0.5): int truncates towards zero, so int(-4.4 + 0.5) is -3
# where Math.round(-4.4) is -4. Every cell index in here is negative half the
# time, so this matters everywhere it is used.
sub round_half { return floor($_[0] + 0.5); }

sub settings {
    my ($options) = @_;
    my %s = (%DEFAULTS, %{ $options || {} });
    return \%s;
}

##############################################################################
# Reading a session
##############################################################################

# Header, poses, scans and summary of a session file as 74_NeatoLocal writes
# it. JSON Lines, one record per line, four kinds; a line starting with '#' is
# a comment (the fixtures have them, real recordings do not).
#
# A run still in progress can be caught mid-write, so the last line may be half
# a record. Everything before it is still good, and a broken line is skipped
# rather than fatal.
sub parse_session {
    my ($text) = @_;
    my $json = JSON::PP->new->utf8(0);
    my %head;
    my (@poses, @scans);
    my $summary;

    for my $line (split(/\n/, defined($text) ? $text : "")) {
        $line =~ s/^\s+|\s+$//g;
        next if (!length($line) || substr($line, 0, 1) eq '#');

        my $record = eval { $json->decode($line) };
        next if (!defined($record) || ref($record) ne "HASH");

        if (defined($record->{device})) {
            %head = (%head, %$record);
        } elsif (defined($record->{scan})) {
            push(@scans, $record->{scan});
        } elsif (defined($record->{summary})) {
            $summary = $record->{summary};
        } elsif (defined($record->{x}) && defined($record->{y})) {
            push(@poses, $record);
        }
    }

    return { head => \%head, poses => \@poses, scans => \@scans, summary => $summary };
}

sub read_session {
    my ($path) = @_;
    open(my $fh, "<", $path) or return undef;
    local $/ = undef;
    my $text = <$fh>;
    close($fh);
    return parse_session($text);
}

##############################################################################
# Laying the revolutions of one run on top of each other
##############################################################################

# A wall seen at ten past ten and again at half past eleven does not land in
# the same place: the robot knows where it is to within a few centimetres, and
# over an hour those centimetres turn one wall into a bundle of strokes. So
# every revolution is nudged until its points sit as well as possible on the
# map all the others draw.
#
# The track is NOT touched. The poses the module recorded are what the robot
# drove; only the scans are moved, and only for the map.
sub align_scans {
    my ($scans, $options) = @_;
    my $s = settings($options);

    return $scans if (scalar(@$scans) < 3);

    my @poses = map { { x => $_->{x}, y => $_->{y}, th => $_->{th} } } @$scans;

    # Angle and distance per revolution, thinned, with the sine and cosine of
    # the angle taken once. The JavaScript takes them inside the scoring loop,
    # where they are recomputed for every position tried; the numbers are the
    # same, this just does not ask for them a thousand times over.
    my @beams;
    for my $scan (@$scans) {
        my $pts = $scan->{pts} || [];
        # ceil, not int: perl's int rounds down, so 276 points against a
        # budget of 130 would take every second point where the reference
        # takes every third - a different thinning and a different fit.
        my $step = ceil(scalar(@$pts) / $s->{alignSample});
        $step = 1 if ($step < 1);
        my @beam;
        for (my $i = 0; $i < scalar(@$pts); $i += $step) {
            my $radians = $pts->[$i][0] * 3.14159265358979 / 180;
            push(@beam, [ cos($radians), sin($radians), $pts->[$i][1] / 1000.0 ]);
        }
        push(@beams, \@beam);
    }

    my $bounds = _extent(\@poses, \@beams);
    return $scans if (!defined($bounds));

    my $moved = 0;
    for my $round (1 .. $s->{alignRounds}) {
        my $map = _density(\@beams, \@poses, $bounds, $s->{alignCell});
        $moved = 0;

        for (my $i = 0; $i < scalar(@$scans); $i++) {
            my $before = $poses[$i];
            my $after  = _fit_pose($beams[$i], $before, $map, $bounds, $s);
            $moved += sqrt(($after->{x} - $before->{x}) ** 2 + ($after->{y} - $before->{y}) ** 2);
            $poses[$i] = $after;
        }

        $moved /= scalar(@$scans);
        # Once the average nudge is under a centimetre there is nothing left to
        # win, and another round costs as much as the first.
        last if ($moved < 0.01);
    }

    my @out;
    for (my $i = 0; $i < scalar(@$scans); $i++) {
        push(@out, { %{ $scans->[$i] }, x => $poses[$i]{x}, y => $poses[$i]{y}, th => $poses[$i]{th} });
    }
    return \@out;
}

sub _extent {
    my ($poses, $beams) = @_;
    my ($minX, $maxX, $minY, $maxY);

    for (my $i = 0; $i < scalar(@$poses); $i++) {
        my $heading = $poses->[$i]{th} * 3.14159265358979 / 180;
        my $ch = cos($heading);
        my $sh = sin($heading);
        for my $beam (@{ $beams->[$i] }) {
            my ($ca, $sa, $distance) = @$beam;
            my $x = $poses->[$i]{x} + $distance * ($ch * $ca - $sh * $sa);
            my $y = $poses->[$i]{y} + $distance * ($sh * $ca + $ch * $sa);
            $minX = $x if (!defined($minX) || $x < $minX);
            $maxX = $x if (!defined($maxX) || $x > $maxX);
            $minY = $y if (!defined($minY) || $y < $minY);
            $maxY = $y if (!defined($maxY) || $y > $maxY);
        }
    }

    return undef if (!defined($minX));

    # Room for the nudging, so nothing falls off the map on the way.
    return { minX => $minX - 1, maxX => $maxX + 1, minY => $minY - 1, maxY => $maxY + 1 };
}

sub _density {
    my ($beams, $poses, $bounds, $cell) = @_;
    my $width  = int(($bounds->{maxX} - $bounds->{minX}) / $cell) + 2;
    my $height = int(($bounds->{maxY} - $bounds->{minY}) / $cell) + 2;
    my @counts = (0) x ($width * $height);

    for (my $i = 0; $i < scalar(@$beams); $i++) {
        my $heading = $poses->[$i]{th} * 3.14159265358979 / 180;
        my $ch = cos($heading);
        my $sh = sin($heading);
        my $px = $poses->[$i]{x};
        my $py = $poses->[$i]{y};

        for my $beam (@{ $beams->[$i] }) {
            my ($ca, $sa, $distance) = @$beam;
            my $x = $px + $distance * ($ch * $ca - $sh * $sa);
            my $y = $py + $distance * ($sh * $ca + $ch * $sa);
            my $ix = floor(($x - $bounds->{minX}) / $cell);
            my $iy = floor(($y - $bounds->{minY}) / $cell);
            next if ($ix < 0 || $iy < 0 || $ix >= $width || $iy >= $height);
            $counts[$iy * $width + $ix]++;
        }
    }

    return { counts => \@counts, width => $width, height => $height, cell => $cell };
}

sub _score_pose {
    my ($beam, $pose, $map, $bounds) = @_;
    my $heading = $pose->{th} * 3.14159265358979 / 180;
    my $ch = cos($heading);
    my $sh = sin($heading);
    my $px = $pose->{x};
    my $py = $pose->{y};
    my $counts = $map->{counts};
    my $width  = $map->{width};
    my $height = $map->{height};
    my $cell   = $map->{cell};
    my $minX   = $bounds->{minX};
    my $minY   = $bounds->{minY};
    my $sum = 0;

    for my $b (@$beam) {
        my $x = $px + $b->[2] * ($ch * $b->[0] - $sh * $b->[1]);
        my $y = $py + $b->[2] * ($sh * $b->[0] + $ch * $b->[1]);
        my $ix = floor(($x - $minX) / $cell);
        my $iy = floor(($y - $minY) / $cell);
        next if ($ix < 0 || $iy < 0 || $ix >= $width || $iy >= $height);
        my $count = $counts->[$iy * $width + $ix];
        # Capped: a spot where two hundred points pile up must not outvote
        # everything else on the wall.
        $sum += $count > 20 ? 20 : $count;
    }

    return $sum;
}

# Plain hill climbing over three numbers, coarse steps first. The recorded pose
# is already close, and the map it climbs is bumpy enough that anything
# cleverer would not be more reliable.
sub _fit_pose {
    my ($beam, $pose, $map, $bounds, $s) = @_;
    my $best = $pose;
    my $bestScore = _score_pose($beam, $best, $map, $bounds);

    for my $step (0.08, 0.04, 0.02) {
        my $turn = $step * 20;              # 1.6, 0.8, 0.4 degrees
        my $improved = 1;

        while ($improved) {
            $improved = 0;
            my @moves = (
                { x => $best->{x} + $step, y => $best->{y}, th => $best->{th} },
                { x => $best->{x} - $step, y => $best->{y}, th => $best->{th} },
                { x => $best->{x}, y => $best->{y} + $step, th => $best->{th} },
                { x => $best->{x}, y => $best->{y} - $step, th => $best->{th} },
                { x => $best->{x}, y => $best->{y}, th => $best->{th} + $turn },
                { x => $best->{x}, y => $best->{y}, th => $best->{th} - $turn },
            );

            for my $move (@moves) {
                next if (sqrt(($move->{x} - $pose->{x}) ** 2 + ($move->{y} - $pose->{y}) ** 2)
                         > $s->{alignReach});
                my $value = _score_pose($beam, $move, $map, $bounds);
                if ($value > $bestScore) {
                    $best = $move;
                    $bestScore = $value;
                    $improved = 1;
                }
            }
        }
    }

    return $best;
}

##############################################################################
# The occupancy grid of one run
##############################################################################

# Hits and passes per cell, from the endpoints and the rays to them. Drawing
# the endpoints alone throws away most of what a lidar says: a beam that stops
# at three metres has also established that everything on the way there was
# empty. Behind the endpoint nothing is claimed.
sub occupancy {
    my ($scans, $cell) = @_;
    $cell = $DEFAULTS{cell} if (!defined($cell));

    my ($minX, $maxX, $minY, $maxY);
    my @world;      # [ [x, y], ... ] per scan, in metres

    for my $scan (@$scans) {
        my $pts = $scan->{pts} || [];
        my @points;
        for my $p (@$pts) {
            # Measured, not derived: heading and lidar angle both count
            # counter-clockwise in degrees and the lidar's zero looks where the
            # robot looks. The mirror image (th -> -th, a -> -a, +180) looks
            # nearly as tidy in a symmetric flat. See docs/ftui3-map.md.
            my $radians = ($scan->{th} + $p->[0]) * 3.14159265358979 / 180;
            my $x = $scan->{x} + $p->[1] / 1000.0 * cos($radians);
            my $y = $scan->{y} + $p->[1] / 1000.0 * sin($radians);
            push(@points, [ $x, $y ]);
            $minX = $x if (!defined($minX) || $x < $minX);
            $maxX = $x if (!defined($maxX) || $x > $maxX);
            $minY = $y if (!defined($minY) || $y < $minY);
            $maxY = $y if (!defined($maxY) || $y > $maxY);
        }
        push(@world, \@points);

        $minX = $scan->{x} if (!defined($minX) || $scan->{x} < $minX);
        $maxX = $scan->{x} if (!defined($maxX) || $scan->{x} > $maxX);
        $minY = $scan->{y} if (!defined($minY) || $scan->{y} < $minY);
        $maxY = $scan->{y} if (!defined($maxY) || $scan->{y} > $maxY);
    }

    if (!defined($minX)) {
        return { x0 => 0, y0 => 0, width => 0, height => 0, cell => $cell,
                 hits => [], misses => [] };
    }

    my $x0 = floor($minX / $cell);
    my $y0 = floor($minY / $cell);
    my $width  = floor($maxX / $cell) - $x0 + 1;
    my $height = floor($maxY / $cell) - $y0 + 1;

    my @hits   = (0) x ($width * $height);
    my @misses = (0) x ($width * $height);

    for (my $s = 0; $s < scalar(@$scans); $s++) {
        my $ox = floor($scans->[$s]{x} / $cell) - $x0;
        my $oy = floor($scans->[$s]{y} / $cell) - $y0;

        for my $point (@{ $world[$s] }) {
            my $tx = floor($point->[0] / $cell) - $x0;
            my $ty = floor($point->[1] / $cell) - $y0;

            # Bresenham from the sensor to the endpoint: the endpoint is the
            # hit, every other cell on the way a pass.
            my $ix = $ox;
            my $iy = $oy;
            my $dx = abs($tx - $ix);
            my $dy = -abs($ty - $iy);
            my $sx = $ix < $tx ? 1 : -1;
            my $sy = $iy < $ty ? 1 : -1;
            my $err = $dx + $dy;

            while (1) {
                last if ($ix == $tx && $iy == $ty);
                $misses[$iy * $width + $ix]++;
                my $doubled = 2 * $err;
                if ($doubled >= $dy) { $err += $dy; $ix += $sx; }
                if ($doubled <= $dx) { $err += $dx; $iy += $sy; }
            }

            $hits[$ty * $width + $tx]++;
        }
    }

    return { x0 => $x0, y0 => $y0, width => $width, height => $height,
             cell => $cell, hits => \@hits, misses => \@misses };
}

# The cells the evidence calls a wall and the ones it calls free, as the world
# coordinates of their centres: [ x0, y0, x1, y1, ... ]. A cell hit in a
# quarter of its observations is a wall, below that free; fewer than minSeen
# observations decide nothing and stay unknown.
sub classify {
    my ($grid, $threshold, $seen) = @_;
    $threshold = $DEFAULTS{threshold} if (!defined($threshold));
    $seen      = $DEFAULTS{minSeen}   if (!defined($seen));

    my (@walls, @free);
    my $cell = $grid->{cell};

    for (my $iy = 0; $iy < $grid->{height}; $iy++) {
        my $row = $iy * $grid->{width};
        my $wy = ($iy + $grid->{y0} + 0.5) * $cell;

        for (my $ix = 0; $ix < $grid->{width}; $ix++) {
            my $hit = $grid->{hits}[$row + $ix];
            my $total = $hit + $grid->{misses}[$row + $ix];
            next if ($total < $seen);

            my $wx = ($ix + $grid->{x0} + 0.5) * $cell;
            if ($hit / $total >= $threshold) {
                push(@walls, $wx, $wy);
            } else {
                push(@free, $wx, $wy);
            }
        }
    }

    return { walls => \@walls, free => \@free };
}

# What one recording contributes: its wall cells and its free cells, in metres.
sub survey {
    my ($session, $options) = @_;
    my $s = settings($options);

    my $scans = scalar(@{ $session->{scans} }) > 2
        ? align_scans($session->{scans}, $s)
        : $session->{scans};

    my $grid  = occupancy($scans, $s->{cell});
    my $cells = classify($grid, $s->{threshold}, $s->{minSeen});

    return {
        walls => $cells->{walls},
        free  => $cells->{free},
        cell  => $s->{cell},
        scans => scalar(@$scans),
    };
}

##############################################################################
# Fitting the runs to each other
##############################################################################

sub _key { return $_[0] * 100000 + $_[1]; }

# The frame a run is matched against: its wall cells, smeared a little. Without
# the smear the score is a cliff - a run half a cell off scores zero and the
# search has nothing to climb. With it, getting closer pays.
sub frame_of {
    my ($walls, $options) = @_;
    my $s = settings($options);
    my %weights;
    my ($minX, $maxX, $minY, $maxY);
    my $reach = $s->{slack} + 1;

    for (my $i = 0; $i < scalar(@$walls); $i += 2) {
        my $x = $walls->[$i];
        my $y = $walls->[$i + 1];
        $minX = $x if (!defined($minX) || $x < $minX);
        $maxX = $x if (!defined($maxX) || $x > $maxX);
        $minY = $y if (!defined($minY) || $y < $minY);
        $maxY = $y if (!defined($maxY) || $y > $maxY);

        my $ix = round_half($x / $s->{cell});
        my $iy = round_half($y / $s->{cell});
        for (my $dx = -$reach; $dx <= $reach; $dx++) {
            for (my $dy = -$reach; $dy <= $reach; $dy++) {
                my $away = sqrt($dx * $dx + $dy * $dy);
                next if ($away > $reach + 0.2);
                my $key = _key($ix + $dx, $iy + $dy);
                my $weight = 1 / (1 + $away);
                $weights{$key} = $weight
                    if (!defined($weights{$key}) || $weights{$key} < $weight);
            }
        }
    }

    return {
        weights => \%weights,
        cell    => $s->{cell},
        bounds  => defined($minX)
            ? { minX => $minX, maxX => $maxX, minY => $minY, maxY => $maxY }
            : { minX => 0, maxX => 0, minY => 0, maxY => 0 },
    };
}

# How well a run sits in a frame, turned and shifted. Between 0 and 1.
sub fits {
    my ($frame, $walls, $angle, $x, $y, $every) = @_;
    $every = 1 if (!defined($every) || $every < 1);

    my $cos = cos($angle);
    my $sin = sin($angle);
    my $stride = 2 * $every;
    my $cell = $frame->{cell};
    my $weights = $frame->{weights};
    my $sum = 0;
    my $count = 0;

    for (my $i = 0; $i < scalar(@$walls); $i += $stride) {
        my $px = $cos * $walls->[$i] - $sin * $walls->[$i + 1] + $x;
        my $py = $sin * $walls->[$i] + $cos * $walls->[$i + 1] + $y;
        my $key = floor($px / $cell + 0.5) * 100000 + floor($py / $cell + 0.5);
        $sum += $weights->{$key} if (exists($weights->{$key}));
        $count++;
    }

    return $count ? $sum / $count : 0;
}

# One rotation, swept over the whole frame. Same arithmetic as calling fits()
# for every position, with the rotation lifted out of the loop: it does not
# depend on the shift, and the sweep asks for it two thousand times per angle.
# Nothing about the result changes, it is just not recomputed.
sub _sweep_angle {
    my ($frame, $walls, $angle, $bounds, $step, $every) = @_;
    my $cos = cos($angle);
    my $sin = sin($angle);
    my $cell = $frame->{cell};
    my $weights = $frame->{weights};

    my (@rx, @ry);
    for (my $i = 0; $i < scalar(@$walls); $i += 2 * $every) {
        push(@rx, $cos * $walls->[$i] - $sin * $walls->[$i + 1]);
        push(@ry, $sin * $walls->[$i] + $cos * $walls->[$i + 1]);
    }
    my $count = scalar(@rx);
    return { angle => $angle, x => 0, y => 0, score => 0 } if (!$count);

    my $best = { angle => $angle, x => 0, y => 0, score => -1 };
    for (my $x = $bounds->[0]; $x <= $bounds->[1]; $x += $step) {
        for (my $y = $bounds->[2]; $y <= $bounds->[3]; $y += $step) {
            my $sum = 0;
            for (my $i = 0; $i < $count; $i++) {
                # One lookup, not exists() and then the value: this line runs
                # some eighty million times per run.
                my $weight = $weights->{ floor(($rx[$i] + $x) / $cell + 0.5) * 100000
                                       + floor(($ry[$i] + $y) / $cell + 0.5) };
                $sum += $weight if (defined($weight));
            }
            my $score = $sum / $count;
            $best = { angle => $angle, x => $x, y => $y, score => $score }
                if ($score > $best->{score});
        }
    }

    return $best;
}

# Where a run belongs in a frame: turned by angle, moved by x and y.
#
# Every rotation in three degree steps, each with a sweep over the frame, and
# the best one refined. This is the part the JavaScript shortcuts with the
# dominant wall direction; here it is simply done, because a forked process may
# take its time and a stupid search has nothing to be wrong about.
sub register_to {
    my ($frame, $run, $options) = @_;
    my $s = settings($options);
    my $b = $frame->{bounds};

    # Every nth cell for the sweep: the sweep only has to find the right
    # neighbourhood, the refinement below uses all of them.
    my $points = scalar(@{ $run->{walls} }) / 2;
    my $sparse = round_half($points / 400);
    $sparse = 1 if ($sparse < 1);

    my @angles;
    for (my $degrees = 0; $degrees < 360; $degrees += $s->{sweep}) {
        push(@angles, $degrees * 3.14159265358979 / 180);
    }

    my $span = [ $b->{minX} - $s->{margin}, $b->{maxX} + $s->{margin},
                 $b->{minY} - $s->{margin}, $b->{maxY} + $s->{margin} ];

    my $best = { angle => $angles[0], x => 0, y => 0, score => -1 };
    for my $angle (@angles) {
        my $found = _sweep_angle($frame, $run->{walls}, $angle, $span, $s->{step}, $sparse);
        $best = $found if ($found->{score} > $best->{score});
    }

    for my $stage (@{ $s->{stages} }) {
        my ($degrees, $metres) = @$stage;
        my $radians = $degrees * 3.14159265358979 / 180;
        my $local = { %$best, score => fits($frame, $run->{walls}, $best->{angle}, $best->{x}, $best->{y}) };

        for (my $a = -3; $a <= 3; $a++) {
            for (my $dx = -3; $dx <= 3; $dx++) {
                for (my $dy = -3; $dy <= 3; $dy++) {
                    my $angle = $best->{angle} + $a * $radians;
                    my $x = $best->{x} + $dx * $metres;
                    my $y = $best->{y} + $dy * $metres;
                    my $score = fits($frame, $run->{walls}, $angle, $x, $y);
                    $local = { angle => $angle, x => $x, y => $y, score => $score }
                        if ($score > $local->{score});
                }
            }
        }

        $best = $local;
    }

    return $best;
}

##############################################################################
# Several runs as one plan
##############################################################################

# The run with the most wall cells is the frame - it knows the flat best - and
# the others are matched against it. Every cell then carries two numbers: seen,
# how many runs looked at that spot at all, and walls, how many of those call
# it a wall. A run that never got into the room does not get to vote about it.
#
# Runs that do not fit are dropped and named in 'rejected'. Forcing a run that
# shares no walls with the others - another floor, another flat - into the
# picture would ruin the plan it is added to.
sub merge_plan {
    my ($surveys, $options) = @_;
    my $s = settings($options);

    if (!scalar(@$surveys)) {
        return { cells => [], placements => [], rejected => [], cell => $s->{cell}, runs => 0 };
    }

    my @order = sort { scalar(@{ $b->{survey}{walls} }) <=> scalar(@{ $a->{survey}{walls} }) }
                map { { survey => $surveys->[$_], index => $_ } } (0 .. $#$surveys);

    my $first = $order[0];
    my $frame = frame_of($first->{survey}{walls}, $s);
    my @placements = ({ index => $first->{index}, angle => 0, x => 0, y => 0, score => 1 });
    my @rejected;

    for my $other (@order[1 .. $#order]) {
        my $fit = register_to($frame, $other->{survey}, $s);
        if ($fit->{score} >= $s->{accept}) {
            push(@placements, { index => $other->{index}, %$fit });
        } else {
            push(@rejected, { index => $other->{index}, score => $fit->{score} });
        }
    }

    # The vote. The cells of the plan are the cells that were MEASURED - the
    # slack belongs in who confirms them, not in how many there are.
    my %measured;
    my @looked;

    for my $placement (@placements) {
        my $survey = $surveys->[$placement->{index}];
        my $cos = cos($placement->{angle});
        my $sin = sin($placement->{angle});

        my $keys = sub {
            my ($points, $reach) = @_;
            my %out;
            for (my $i = 0; $i < scalar(@$points); $i += 2) {
                my $px = $cos * $points->[$i] - $sin * $points->[$i + 1] + $placement->{x};
                my $py = $sin * $points->[$i] + $cos * $points->[$i + 1] + $placement->{y};
                my $ix = round_half($px / $s->{cell});
                my $iy = round_half($py / $s->{cell});
                for (my $dx = -$reach; $dx <= $reach; $dx++) {
                    for (my $dy = -$reach; $dy <= $reach; $dy++) {
                        $out{ _key($ix + $dx, $iy + $dy) } = 1;
                    }
                }
            }
            return \%out;
        };

        my $raw = $keys->($survey->{walls}, 0);
        $measured{$_} = 1 for (keys %$raw);
        push(@looked, { near => $keys->($survey->{walls}, $s->{slack}),
                        free => $keys->($survey->{free}, 0) });
    }

    my @cells;
    for my $key (sort { $a <=> $b } keys %measured) {
        my $walls = 0;
        my $seen  = 0;
        for my $run (@looked) {
            my $saysWall = exists($run->{near}{$key});
            $walls++ if ($saysWall);
            # A run has looked at a cell if it knows it as floor or as wall.
            # One that never came near says nothing, and is not a vote against.
            $seen++ if ($saysWall || exists($run->{free}{$key}));
        }
        my $ix = round_half($key / 100000);
        push(@cells, { ix => $ix, iy => $key - $ix * 100000, walls => $walls, seen => $seen });
    }

    return { cells => \@cells, placements => \@placements, rejected => \@rejected,
             cell => $s->{cell}, runs => scalar(@placements) };
}

# How well each offered run sits in the frame, best first.
#
# All of them, not just the ones that made it: the threshold below which a run
# is dropped is an assumption and not a measurement, and this list is the only
# place the numbers that would settle it can collect. The frame run scores 1 by
# definition -- it is what the others are measured against.
#
# $names is indexed the same way the surveys were, so placements and rejects
# can both name their file.
sub scores_of {
    my ($plan, $names) = @_;
    my @scores;

    for my $placement (@{ $plan->{placements} }) {
        push(@scores, { file  => $names->[$placement->{index}],
                        score => $placement->{score},
                        used  => 1 });
    }
    for my $rejected (@{ $plan->{rejected} }) {
        push(@scores, { file  => $names->[$rejected->{index}],
                        score => $rejected->{score},
                        used  => 0 });
    }

    return [ sort { $b->{score} <=> $a->{score} } @scores ];
}

# The plan as the JSON the component reads. Cell indices, not metres.
#
# $names is every run that was offered, indexed as the surveys were. "files"
# names the ones that went in, in the order they were fitted -- the first is
# the frame; "scores" names all of them with the grade each one got.
sub as_json {
    my ($plan, $names, $built) = @_;
    my @cells = map { "[$_->{ix},$_->{iy},$_->{walls},$_->{seen}]" } @{ $plan->{cells} };
    my @parts = (
        sprintf('"cell":%s', _number($plan->{cell})),
        sprintf('"runs":%d', $plan->{runs}),
    );
    push(@parts, sprintf('"built":"%s"', $built)) if (defined($built));

    if (defined($names)) {
        my @files = map { '"' . _escape($names->[$_->{index}]) . '"' }
                    @{ $plan->{placements} };
        push(@parts, '"files":[' . join(",", @files) . ']');

        my @scores = map {
            sprintf('{"file":"%s","score":%s,"used":%s}',
                    _escape($_->{file}), _score($_->{score}), $_->{used} ? "true" : "false")
        } @{ scores_of($plan, $names) };
        push(@parts, '"scores":[' . join(",", @scores) . ']') if (scalar(@scores));
    }

    push(@parts, '"cells":[' . join(",", @cells) . ']');

    return "{" . join(",", @parts) . "}\n";
}

# A grade as a JSON number: three decimals, without the trailing zeros that
# would only make the file longer. 1.000 becomes 1, 0.330 becomes 0.33.
sub _score {
    my ($value) = @_;
    my $text = sprintf("%.3f", $value);
    $text =~ s/0+$// if ($text =~ m/\./);
    $text =~ s/\.$//;
    return $text;
}

sub _number {
    my ($value) = @_;
    my $text = sprintf("%.10g", $value);
    return $text;
}

sub _escape {
    my ($text) = @_;
    $text =~ s/(["\\])/\\$1/g;
    $text =~ s/[\r\n\t]/ /g;
    return $text;
}

1;
