#!/usr/bin/perl
# Drives the module's over-the-air update against a stand-in for the bridge.
#
# This is the one test that matters for OTA: the protocol is not ours, and a
# client tested only against my own idea of it proves nothing. The simulator is
# written from the device's own implementation, and the image is compared byte
# for byte after the transfer -- a client that sends the right bytes in the wrong
# order would otherwise pass.

use strict;
use warnings;
use Test::More tests => 14;
use File::Temp qw(tempdir);

my $dir = tempdir(CLEANUP => 1);

# --- FHEM stubs, enough for the worker ------------------------------------
our %defs;
our %attr;
sub Log3 { }
sub ReadingsVal { my (undef, undef, $default) = @_; return $default; }
sub AttrVal { my (undef, undef, $default) = @_; return $default; }
sub readingsSingleUpdate { }
sub readingsBeginUpdate { }
sub readingsBulkUpdate { }
sub readingsBulkUpdateIfChanged { }
sub readingsEndUpdate { }
sub InternalTimer { }
sub RemoveInternalTimer { }
sub BlockingCall { }
sub CommandModify { return undef; }
sub IsDisabled { return 0; }
sub DevIo_OpenDev { return undef; }
sub DevIo_CloseDev { return undef; }
sub DevIo_SimpleWrite { }
sub DevIo_SimpleRead { return undef; }
sub gettimeofday { return time(); }
our $readingFnAttributes = "";
our $init_done = 1;

# The module is Perl, not a package: read it and evaluate it here.
my $code = do {
    open(my $fh, "<", "FHEM/74_NeatoLocal.pm") or die "cannot read the module: $!";
    local $/;
    <$fh>;
};
$code =~ s/^\s*use strict;\s*$//m;
$code =~ s/^\s*use warnings;\s*$//m;
$code =~ s/^\s*use Time::HiRes.*$//m;
eval "package main; $code 1;" or die "cannot load the module: $@";

# --- a firmware-shaped image ---------------------------------------------
my $image = "$dir/app.bin";
{
    open(my $fh, ">", $image) or die $!;
    binmode($fh);
    # 0xE9 magic, then something long enough to pass the size check and varied
    # enough that a mangled transfer cannot look correct.
    print $fh chr(0xE9);
    for my $i (1 .. 150000) {
        print $fh chr($i % 256);
    }
    close($fh);
}
my $size = -s $image;
ok($size > 100000, "the test image is firmware-shaped ($size bytes)");

# --- run one update against the simulator --------------------------------
sub run_ota {
    my ($mode, $outfile) = @_;

    my $cmd = "python3 tools/ota_sim.py --mode " . $mode
            . ($outfile ? " --out " . $outfile : "") . " 2>>$dir/sim.log";
    open(my $sim, "-|", $cmd) or die "cannot start the simulator: $!";

    my $port = <$sim>;
    die "the simulator did not report its port" if (!defined($port));
    chomp($port);

    my $result = NeatoLocal_OtaWork("dev|127.0.0.1|$port|$image");

    close($sim);
    return $result;
}

# --- the case that has to work -------------------------------------------
my $received = "$dir/received.bin";
my $result = run_ota("ok", $received);

like($result, qr/^dev\|OK\|/, "a plain update succeeds");
like($result, qr/$size bytes written/, "and reports the whole image");

ok(-e $received, "the simulator wrote what it got");
is(-s $received, $size, "the byte count matches");

# Byte for byte: order and content, not just length.
sub slurp {
    my ($path) = @_;
    open(my $fh, "<", $path) or die $!;
    binmode($fh);
    local $/;
    return <$fh>;
}
is(Digest::MD5::md5_hex(slurp($received)), Digest::MD5::md5_hex(slurp($image)),
   "the image arrives unchanged");

# --- and the ways it can fail --------------------------------------------
$result = run_ota("auth");
like($result, qr/OTA password/, "a bridge asking for a password says so");
unlike($result, qr/^dev\|OK/, "and is not reported as success");

$result = run_ota("silent");
like($result, qr/no answer to the update invitation/,
     "a bridge that ignores the invitation is named");

$result = run_ota("refuse");
like($result, qr/never connected back/,
     "one that answers but does not connect back is a separate case");

$result = run_ota("badend");
like($result, qr/did not accept the image/, "a rejected image is a failure");
like($result, qr/bad magic byte/, "with the reason the bridge gave");

# --- and the checks before anything is sent ------------------------------
$result = NeatoLocal_OtaWork("dev|127.0.0.1|3232|$dir/nothing-here.bin");
like($result, qr/image not readable/, "a missing image is refused up front");

open(my $small, ">", "$dir/small.bin"); print $small "x"; close($small);
$result = NeatoLocal_OtaWork("dev|127.0.0.1|3232|$dir/small.bin");
like($result, qr/too small/, "and so is something that is not a firmware");
