#!/usr/bin/perl
##############################################################################
# Checks FHEM/lib/NeatoLocalPlan.pm against the reference case.
#
#     perl tools/check_plan.pl                    # bauen und vergleichen
#     perl tools/check_plan.pl --quick            # nur die schnellen Pruefungen
#     perl tools/check_plan.pl mein.json --against anderer.json
#
# The floor plan is a seam between two projects: this module computes it, the
# FTUI component draws it, and a JSON file is all they share. The other side
# has tools/check-plan.mjs for exactly this; this is the same comparison in
# perl, so the CI here can run it without node.
#
# What it does NOT demand is equality to the last cell. Fitting runs onto each
# other is a hill climb, and a hill climb in another language finds a slightly
# different hilltop. Measured instead: agreement within one cell, both ways,
# the same verdict about which cells are settled, and a cell count that has
# not quietly lost a third of the flat.
#
# Copyright and license: see LICENSE (GPLv2) in the repository root.
##############################################################################

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../FHEM/lib";
use NeatoLocalPlan;
use JSON::PP;
use POSIX qw(floor);
use Time::HiRes qw(time);

my $failed = 0;

sub ok {
    my ($condition, $what) = @_;
    if ($condition) {
        printf("ok     %s\n", $what);
    } else {
        printf("FEHLER %s\n", $what);
        $failed++;
    }
    return $condition;
}

sub slurp {
    my ($path) = @_;
    open(my $fh, "<", $path) or die("$path: $!\n");
    local $/ = undef;
    my $text = <$fh>;
    close($fh);
    return $text;
}

my $here = "$FindBin::Bin/..";
my $reference = "$here/docs/reference-plan";
my $quick = grep { $_ eq "--quick" } @ARGV;

##############################################################################
# The pieces, where the answer is known by construction
##############################################################################

print("Die Bausteine\n");

# Perl's int() truncates towards zero, JavaScript's Math.round goes towards
# plus infinity. Every cell index here is negative half the time, so a port
# that uses int($x + 0.5) is off by one over the whole left half of the flat.
ok(NeatoLocalPlan::round_half(4.4) == 4 && NeatoLocalPlan::round_half(4.5) == 5,
   "aufrunden: 4.4 wird 4, 4.5 wird 5");
ok(NeatoLocalPlan::round_half(-4.4) == -4, "und -4.4 wird -4, nicht -3 wie bei int()");
ok(NeatoLocalPlan::round_half(-4.5) == -4, "-4.5 wird -4, wie Math.round");
ok(int(-4.4 + 0.5) == -3, "zum Vergleich: int(-4.4 + 0.5) ist wirklich -3");

# A single beam, two metres straight ahead from the origin, at ten centimetre
# cells: the cells on the way are free, the last one is a wall, and behind it
# nothing is claimed at all.
{
    my $scans = [ { x => 0, y => 0, th => 0, pts => [ [ 0, 2000 ] ] } ];
    my $grid = NeatoLocalPlan::occupancy($scans, 0.1);
    my $hits = 0;
    my $misses = 0;
    $hits += $_ for (@{ $grid->{hits} });
    $misses += $_ for (@{ $grid->{misses} });

    ok($hits == 1, "ein Strahl trifft genau eine Zelle");
    ok($misses == 20, "und durchquert die zwanzig davor (er ist zwei Meter lang)");
    ok($grid->{width} == 21 && $grid->{height} == 1,
       "das Gitter endet am Endpunkt, dahinter wird nichts behauptet");

    my $cells = NeatoLocalPlan::classify($grid, 0.25, 1);
    ok(scalar(@{ $cells->{walls} }) == 2, "eine Wandzelle");
    ok(scalar(@{ $cells->{free} }) == 40, "und zwanzig freie");
}

# The slack belongs in the vote, not in the set of cells. Counting the widened
# sets turns 1800 measured cells into 5000 and gives the flat metre-thick
# walls - it is the mistake the first version of the procedure made, so it is
# held down here: one run alone must yield exactly its own wall cells.
{
    # Cell centres the way classify() computes them. Typed out as literals
    # they are not the same doubles - 0.15 and 1.5 * 0.1 differ in the last
    # bit, and a cell boundary is exactly where that decides the cell.
    my $centre = sub { return ($_[0] + 0.5) * 0.1; };
    my $survey = {
        walls => [ $centre->(0), $centre->(0), $centre->(1), $centre->(0), $centre->(2), $centre->(0) ],
        free  => [ $centre->(0), $centre->(1) ],
        cell  => 0.1,
    };
    my $plan = NeatoLocalPlan::merge_plan([ $survey ]);
    ok(scalar(@{ $plan->{cells} }) == 3,
       "drei gemessene Wandzellen bleiben drei, nicht die aufgeweiteten neun");
    ok($plan->{runs} == 1, "und der Lauf ist sein eigener Rahmen");
    my ($walls) = map { $_->{walls} } @{ $plan->{cells} };
    ok($walls == 1, "die ein Lauf Wand nennt, nennt ein Lauf Wand");
}

# A run that does not belong has to be refused rather than forced in: another
# floor in the same frame drags walls through rooms. The case is built so the
# answer is fixed beforehand - the frame is one wall, the run is three
# parallel walls three metres apart, and no turning or shifting can put more
# than one of the three onto the one. A third of the run fits, and a third is
# below the threshold, so it has to be dropped.
{
    my @one;
    push(@one, $_ * 0.1, 0) for (0 .. 60);

    my @three;
    for my $lane (0, 3, 6) {
        push(@three, $_ * 0.1, $lane) for (0 .. 60);
    }

    my $frame = NeatoLocalPlan::frame_of(\@one);
    my $fit = NeatoLocalPlan::register_to($frame, { walls => \@three });
    ok($fit->{score} > 0.28 && $fit->{score} < 0.40,
       sprintf("von drei Waenden passt eine auf eine: Guete %.2f", $fit->{score}));
    ok($fit->{score} < $NeatoLocalPlan::DEFAULTS{accept},
       sprintf("und das liegt unter der Schwelle von %.2f", $NeatoLocalPlan::DEFAULTS{accept}));

    # Through merge_plan, where the frame is whichever run has the most wall
    # cells: three lanes three metres apart against three one metre apart.
    # Whichever lane is brought onto a lane of the frame, the other two are a
    # metre or more off - far past the tolerance of one cell.
    my @tight;
    for my $lane (0, 1, 2) {
        push(@tight, $_ * 0.1, $lane) for (0 .. 50);
    }
    my $plan = NeatoLocalPlan::merge_plan([ { walls => \@tight, free => [] },
                                            { walls => \@three, free => [] } ]);
    ok($plan->{runs} == 1 && scalar(@{ $plan->{rejected} }) == 1,
       "und im Plan landet er unter den abgelehnten, nicht in der Karte");
}

##############################################################################
# The reference case
##############################################################################

my ($mine, $theirs, $label);

sub inspect {
    my ($raw, $what) = @_;
    my @cells;
    my %seen;

    die("$what: cell fehlt\n") if (!($raw->{cell} > 0));
    die("$what: cells ist keine Liste\n") if (ref($raw->{cells}) ne "ARRAY");
    my $runs = $raw->{runs};
    die("$what: runs ist keine Zahl >= 1\n") if (!defined($runs) || $runs !~ m/^\d+$/ || $runs < 1);

    for my $entry (@{ $raw->{cells} }) {
        die("$what: eine Zelle ist kein [ix, iy, walls, seen]\n")
            if (ref($entry) ne "ARRAY" || scalar(@$entry) < 3);
        my ($ix, $iy, $walls) = @$entry;
        my $looked = scalar(@$entry) > 3 ? $entry->[3] : $walls;

        die("$what: Zellindex $ix,$iy ist nicht ganzzahlig - das sind Zellen, keine Meter\n")
            if ($ix != int($ix) || $iy != int($iy));
        die("$what: walls = $walls; eine Zelle, die niemand Wand nennt, gehoert nicht hinein\n")
            if ($walls != int($walls) || $walls < 1);
        die("$what: seen = $looked gegen walls = $walls\n")
            if ($looked != int($looked) || $looked < $walls);
        die("$what: seen = $looked, aber der Plan ist aus $runs Laeufen\n") if ($looked > $runs);
        die("$what: Zelle $ix,$iy kommt doppelt vor\n") if ($seen{"$ix,$iy"}++);

        push(@cells, { ix => $ix, iy => $iy, walls => $walls, seen => $looked });
    }

    die("$what: keine brauchbaren Zellen\n") if (!scalar(@cells));
    return { cell => $raw->{cell}, runs => $runs, cells => \@cells };
}

my @plain = grep { $_ !~ m/^--/ } @ARGV;
my $against;
for (my $i = 0; $i < scalar(@ARGV) - 1; $i++) {
    $against = $ARGV[$i + 1] if ($ARGV[$i] eq "--against");
}
@plain = grep { !defined($against) || $_ ne $against } @plain;

if (scalar(@plain)) {
    $mine = inspect(JSON::PP->new->decode(slurp($plain[0])), $plain[0]);
    $label = $plain[0];
    $theirs = inspect(JSON::PP->new->decode(slurp($against)), $against) if (defined($against));
} elsif (!$quick) {
    print("\nDer Referenzfall\n");
    my $started = time;
    my @surveys;
    my @names = qw(room-a.jsonl room-b.jsonl room-c.jsonl);
    for my $name (@names) {
        my $session = NeatoLocalPlan::read_session("$reference/$name");
        die("$reference/$name fehlt\n") if (!defined($session));
        push(@surveys, NeatoLocalPlan::survey($session));
    }
    my $plan = NeatoLocalPlan::merge_plan(\@surveys);
    printf("       %d Laeufe eingepasst, %d Zellen, %.0f s\n",
           $plan->{runs}, scalar(@{ $plan->{cells} }), time - $started);

    ok($plan->{runs} == 3, "alle drei Laeufe passen in einen Rahmen");
    ok(!scalar(@{ $plan->{rejected} }), "keiner wird abgelehnt");

    # Die Guete je Lauf: nicht die Anzeige braucht sie, sondern die Frage, ob
    # die Schwelle von 0,45 an der richtigen Stelle liegt. Sie ist eine Annahme
    # und keine Messung, und dies ist die einzige Stelle, an der sich die
    # Zahlen sammeln, die das entscheiden koennten.
    my $scores = NeatoLocalPlan::scores_of($plan, \@names);
    ok(scalar(@$scores) == 3, "jeder angebotene Lauf bekommt eine Guete, nicht nur die genommenen");
    ok($scores->[0]{score} == 1 && $scores->[0]{used},
       "der Rahmenlauf steht mit 1,0 dabei -- an ihm wird gemessen");
    ok($scores->[0]{score} >= $scores->[1]{score}
       && $scores->[1]{score} >= $scores->[2]{score}, "absteigend sortiert");
    ok(!grep({ !defined($_->{file}) || $_->{file} !~ m/\.jsonl$/ } @$scores),
       "und jede nennt ihre Datei");
    printf("       Guete: %s\n",
           join(", ", map { sprintf("%.2f %s", $_->{score}, $_->{used} ? "dabei" : "abgelehnt") }
                      @$scores));

    # Ein Lauf, der es nicht schafft, muss in der Liste auftauchen und dort als
    # abgelehnt markiert sein -- sonst sieht ein verlorener Lauf nach nichts
    # aus ausser einem kleineren planRuns als erwartet.
    {
        my @lanes;
        for my $lane (0, 3, 6) {
            push(@lanes, $_ * 0.1, $lane) for (0 .. 60);
        }
        my @tight;
        for my $lane (0, 1, 2) {
            push(@tight, $_ * 0.1, $lane) for (0 .. 50);
        }
        my $mixed = NeatoLocalPlan::merge_plan([ { walls => \@tight, free => [] },
                                                 { walls => \@lanes, free => [] } ]);
        my $both = NeatoLocalPlan::scores_of($mixed, [ "breit.jsonl", "eng.jsonl" ]);
        ok(scalar(@$both) == 2, "auch der abgelehnte Lauf steht in der Liste");
        ok($both->[1]{used} == 0 && $both->[1]{score} < $NeatoLocalPlan::DEFAULTS{accept},
           sprintf("als abgelehnt, mit der Guete, die er erreicht hat (%.2f)",
                   $both->[1]{score}));
    }

    # Through the writer and back, so the file format is checked too, not just
    # the arithmetic behind it.
    $mine = inspect(JSON::PP->new->decode(
        NeatoLocalPlan::as_json($plan, \@names, "2026-01-01T00:00:00.000Z")), "der gerechnete Plan");
    $label = "der gerechnete Plan";
    $theirs = inspect(JSON::PP->new->decode(slurp("$reference/plan.json")), "$reference/plan.json");
}

if (!defined($theirs)) {
    print($failed ? "\n$failed Pruefung(en) fehlgeschlagen\n" : "\nalle Pruefungen bestanden\n");
    exit($failed ? 1 : 0);
}

##############################################################################
# The comparison, in the same four measures as tools/check-plan.mjs
##############################################################################

my %LIMITS = (found => 0.95, agree => 0.95, size => 0.15);

sub overlap {
    my ($wanted, $have) = @_;
    my %lookup;
    $lookup{"$_->{ix},$_->{iy}"} = $_ for (@{ $have->{cells} });

    my $settled = sub { return $_[0]{seen} > 1 && $_[0]{walls} / $_[0]{seen} >= 0.5; };
    my ($exact, $near, $kind) = (0, 0, 0);

    for my $cell (@{ $wanted->{cells} }) {
        my $straight = $lookup{"$cell->{ix},$cell->{iy}"};
        $exact++ if (defined($straight));

        my $match = $straight;
        for (my $dx = -1; $dx <= 1 && !defined($match); $dx++) {
            for (my $dy = -1; $dy <= 1 && !defined($match); $dy++) {
                $match = $lookup{ ($cell->{ix} + $dx) . "," . ($cell->{iy} + $dy) };
            }
        }
        if (defined($match)) {
            $near++;
            $kind++ if ($settled->($match) == $settled->($cell));
        }
    }

    my $total = scalar(@{ $wanted->{cells} });
    return { exact => $exact / $total, near => $near / $total, kind => $near ? $kind / $near : 0 };
}

my $found = overlap($theirs, $mine);
my $back  = overlap($mine, $theirs);
my $ratio = scalar(@{ $mine->{cells} }) / scalar(@{ $theirs->{cells} });

printf("\n%s: %d Zellen gegen %d der Referenz\n\n",
       $label, scalar(@{ $mine->{cells} }), scalar(@{ $theirs->{cells} }));
printf("                                     genau    +/-1 Zelle\n");
printf("  von der Referenz wiedergefunden  %7.1f %%%12.1f %%\n", 100 * $found->{exact}, 100 * $found->{near});
printf("  umgekehrt, keine erfunden        %7.1f %%%12.1f %%\n", 100 * $back->{exact}, 100 * $back->{near});
printf("  gleich eingeordnet (sicher/strittig)       %5.1f %%\n", 100 * $found->{kind});
printf("  Zellen gegenueber der Referenz             %5.1f %%\n\n", 100 * $ratio);

ok(abs($ratio - 1) <= $LIMITS{size},
   sprintf("die Zellzahl liegt bei %.1f %%, erlaubt sind %d bis %d",
           100 * $ratio, 100 * (1 - $LIMITS{size}), 100 * (1 + $LIMITS{size})));
ok($found->{near} >= $LIMITS{found},
   sprintf("%.1f %% der Referenzzellen wiedergefunden, verlangt %d", 100 * $found->{near}, 100 * $LIMITS{found}));
ok($back->{near} >= $LIMITS{found},
   sprintf("%.1f %% der eigenen Zellen kennt die Referenz, verlangt %d", 100 * $back->{near}, 100 * $LIMITS{found}));
ok($found->{kind} >= $LIMITS{agree},
   sprintf("%.1f %% gleich eingeordnet, verlangt %d", 100 * $found->{kind}, 100 * $LIMITS{agree}));

print($failed ? "\n$failed Pruefung(en) fehlgeschlagen\n" : "\nalle Pruefungen bestanden\n");
exit($failed ? 1 : 0);
