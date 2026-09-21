#!/usr/bin/perl
##############################################################################
# Writes one floor plan from a folder of recordings.
#
#     perl tools/neato_plan.pl /opt/fhem/www/neato Staubsauger
#     perl tools/neato_plan.pl /opt/fhem/www/neato Staubsauger --runs 10
#     perl tools/neato_plan.pl <verzeichnis> --out plan.json --cell 0.10
#
# The module calls the same code in a forked process; this is the way to run it
# by hand, from cron, or on a machine that has no FHEM at all. It prints what
# it did, which is what makes a plan that came out wrong readable afterwards.
#
# Copyright and license: see LICENSE (GPLv2) in the repository root.
##############################################################################

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../FHEM/lib";
use NeatoLocalPlan;
use Time::HiRes qw(time);

my @args = @ARGV;
sub flag {
    my ($name, $fallback) = @_;
    for (my $i = 0; $i < scalar(@args) - 1; $i++) {
        return $args[$i + 1] if ($args[$i] eq "--$name");
    }
    return $fallback;
}

my @plain;
for (my $i = 0; $i < scalar(@args); $i++) {
    next if ($args[$i] =~ m/^--/);
    next if ($i > 0 && $args[$i - 1] =~ m/^--/);
    push(@plain, $args[$i]);
}

my ($dir, $device) = @plain;
if (!defined($dir)) {
    print STDERR "perl tools/neato_plan.pl <verzeichnis> [geraet]"
        . " [--runs 8] [--cell 0.10] [--out datei] [--quiet]\n";
    exit(2);
}

my $keep  = flag("runs", 8) + 0;
my $cell  = flag("cell", $NeatoLocalPlan::DEFAULTS{cell}) + 0;
my $out   = flag("out", "$dir/plan-" . (defined($device) ? $device : "neato") . ".json");
my $quiet = grep { $_ eq "--quiet" } @args;

sub say { print(@_) if (!$quiet); }

opendir(my $dh, $dir) or die("$dir: $!\n");
my @names = sort { $b cmp $a }
            grep { m/\.jsonl$/ && (!defined($device) || index($_, "$device-") == 0) }
            readdir($dh);
closedir($dh);

@names = @names[0 .. $keep - 1] if ($keep > 0 && scalar(@names) > $keep);

if (!scalar(@names)) {
    print STDERR "Keine Aufzeichnungen in $dir"
        . (defined($device) ? " fuer $device" : "") . ".\n";
    exit(1);
}

my @surveys;
my @used;
for my $name (@names) {
    my $started = time;
    my $session = NeatoLocalPlan::read_session("$dir/$name");
    if (!defined($session) || !scalar(@{ $session->{scans} })) {
        say("$name: keine Scans, uebersprungen\n");
        next;
    }
    push(@surveys, NeatoLocalPlan::survey($session, { cell => $cell }));
    push(@used, $name);
    say(sprintf("%s: %d Scans, %d Wandzellen, %.1f s\n", $name,
                scalar(@{ $session->{scans} }),
                scalar(@{ $surveys[-1]{walls} }) / 2, time - $started));
}

if (!scalar(@surveys)) {
    print STDERR "Keine der Aufzeichnungen hat Scans - ohne mapInterval wird nur die Spur"
        . " aufgezeichnet, und aus einer Spur wird kein Grundriss.\n";
    exit(1);
}

my $started = time;
my $plan = NeatoLocalPlan::merge_plan(\@surveys, { cell => $cell });
say(sprintf("\nZusammengelegt in %.1f s: %d von %d Laeufen, %d Zellen\n",
            time - $started, $plan->{runs}, scalar(@surveys), scalar(@{ $plan->{cells} })));

for my $rejected (@{ $plan->{rejected} }) {
    say(sprintf("  abgelehnt: %s (Guete %.0f %%)\n",
                $used[$rejected->{index}], $rejected->{score} * 100));
}

my @files = map { $used[$_->{index}] } @{ $plan->{placements} };
my @stamp = gmtime(time);
my $built = sprintf("%04d-%02d-%02dT%02d:%02d:%02d.000Z",
                    $stamp[5] + 1900, $stamp[4] + 1, $stamp[3], $stamp[2], $stamp[1], $stamp[0]);
my $body = NeatoLocalPlan::as_json($plan, \@files, $built);

open(my $fh, ">", $out) or die("$out: $!\n");
print $fh $body;
close($fh);

say(sprintf("%s: %.0f kB\n", $out, length($body) / 1024));
