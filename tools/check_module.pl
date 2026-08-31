#!/usr/bin/perl
##############################################################################
# Offline check for 74_NeatoLocal.pm.
#
# FHEM modules are compiled into package main and rely on globals and helper
# subs provided by fhem.pl. This harness provides just enough of them to load
# the module and exercise its parsers against real console output, so the
# response handling can be verified without a robot and without a FHEM
# installation.
#
# Usage: perl tools/check_module.pl
##############################################################################

use strict;
use warnings;
use Test::More tests => 25;

package main;

use vars qw(%defs %attr %modules $init_done $readingFnAttributes);

$init_done           = 1;
$readingFnAttributes = "event-on-change-reading event-on-update-reading";

# --- fhem.pl / DevIo.pm stubs ----------------------------------------------
our @LOG;
our @WRITTEN;
our @TIMERS;

sub Log3                    { push @LOG, join("|", map { defined($_) ? $_ : "" } @_); }
sub InternalTimer           { push @TIMERS, [@_]; }
sub RemoveInternalTimer     { }
sub DevIo_OpenDev           { return undef; }
sub DevIo_CloseDev          { return undef; }
sub DevIo_SimpleWrite       { push @WRITTEN, $_[1]; }
sub DevIo_SimpleRead        { return undef; }
sub HttpUtils_NonblockingGet { }
sub HttpUtils_BlockingGet    { push @WRITTEN, "http:" . $_[0]->{url}; return ("", ""); }
sub asyncOutput             { }
sub urlEncode               { my $s = shift; $s =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X", ord($1))/ge; return $s; }

sub IsDisabled  { my $n = shift; return AttrVal($n, "disable", 0) ? 1 : 0; }
sub AttrVal     { my ($n, $a, $d) = @_; return (defined($attr{$n}) && defined($attr{$n}{$a})) ? $attr{$n}{$a} : $d; }
sub ReadingsVal { my ($n, $r, $d) = @_; return (defined($defs{$n}{READINGS}{$r})) ? $defs{$n}{READINGS}{$r}{VAL} : $d; }

sub readingsBeginUpdate { }
sub readingsEndUpdate   { }
sub readingsBulkUpdate  {
    my ($hash, $reading, $value) = @_;
    $defs{$hash->{NAME}}{READINGS}{$reading}{VAL} = $value;
}
sub readingsBulkUpdateIfChanged { return readingsBulkUpdate(@_); }
sub readingsSingleUpdate        { my ($h, $r, $v) = @_; return readingsBulkUpdate($h, $r, $v); }

# --- load the module -------------------------------------------------------
require "./FHEM/74_NeatoLocal.pm";
pass("module loads and compiles");

my %init;
NeatoLocal_Initialize(\%init);
ok(defined($init{DefFn}) && defined($init{ReadFn}) && defined($init{SetFn}),
   "Initialize registers the FHEM callbacks");
like($init{AttrList}, qr/cmdSendToBase/, "AttrList contains the command mapping attributes");

# --- helper: build a device ------------------------------------------------
sub mkdev {
    my ($def) = @_;
    my $hash = { NAME => "nt", STATE => "opened" };
    $defs{"nt"} = $hash;
    my $ret = NeatoLocal_Define($hash, $def);
    return ($hash, $ret);
}

# --- transport detection ---------------------------------------------------
my ($h, $ret) = mkdev("nt NeatoLocal /dev/ttyACM0");
is($h->{TRANSPORT}, "serial", "serial transport detected");
is($h->{DeviceName}, "/dev/ttyACM0\@115200", "default baudrate appended");

($h, $ret) = mkdev("nt NeatoLocal 192.168.1.42:23");
is($h->{TRANSPORT}, "tcp", "tcp transport detected");

($h, $ret) = mkdev("nt NeatoLocal http://neato.local/");
is($h->{TRANSPORT}, "http", "http transport detected");
is($h->{URL}, "http://neato.local", "trailing slash stripped from URL");

($h, $ret) = mkdev("nt NeatoLocal");
like($ret, qr/Usage/, "wrong argument count is rejected");

# --- echo stripping and CSV parsing ---------------------------------------
my $raw = "GetCharger\r\nLabel,Value\r\nFuelPercent,87\r\nChargingActive,0\r\n"
        . "ExtPwrPresent,1\r\nVBattV,16.32\r\n" . chr(26);
my $body = NeatoLocal_StripEcho("GetCharger", $raw);
unlike($body, qr/GetCharger/, "echoed command is stripped");
unlike($body, qr/\x1a/, "response terminator is stripped");

my $csv = NeatoLocal_ParseCsv($body);
is($csv->{FuelPercent}, "87", "CSV value parsed");
is($csv->{VBattV}, "16.32", "float CSV value parsed");

# --- parsers ---------------------------------------------------------------
($h, $ret) = mkdev("nt NeatoLocal /dev/ttyACM0");
NeatoLocal_ParseCharger($h, { cmd => "GetCharger" }, $body);
is(ReadingsVal("nt", "batteryPercent", ""), "87", "batteryPercent reading set");
is(ReadingsVal("nt", "isDocked", ""), 1, "isDocked derived from ExtPwrPresent");
is(ReadingsVal("nt", "isCharging", ""), 0, "isCharging derived from ChargingActive");
is(ReadingsVal("nt", "state", ""), "docked", "state is docked when on the base");

NeatoLocal_ParseErr($h, { cmd => "GetErr" }, "220 - Please put my Dirt Bin back in.");
is(ReadingsVal("nt", "errorCode", ""), "220", "error code parsed");
is(ReadingsVal("nt", "state", ""), "error", "state switches to error");

NeatoLocal_ParseErr($h, { cmd => "GetErr" }, "");
is(ReadingsVal("nt", "error", ""), "none", "cleared error resets the reading");

NeatoLocal_ParseMotors($h, { cmd => "GetMotors" }, "Brush_RPM,1200\r\nVacuum_RPM,2100\r\n");
is(ReadingsVal("nt", "isCleaning", ""), 1, "cleaning detected from Vacuum_RPM");

NeatoLocal_ParseVersion($h, { cmd => "GetVersion" },
    "Component,Major,Minor,Build\r\nModelID,-1,BotvacD7\r\nSerial Number,KSH12345-0000123\r\n"
  . "MainBoard Software,4,5,3\r\n");
is(ReadingsVal("nt", "serialNumber", ""), "KSH12345-0000123", "serial number parsed");

# --- unconfigured commands must fail loudly, not silently ------------------
my $err = NeatoLocal_Set($h, "nt", "sendToBase");
like($err, qr/cmdSendToBase/, "sendToBase without configured command points at the attribute");

# --- test mode must always be left again -----------------------------------
$h->{helper}{testMode} = 1;
@WRITTEN = ();
NeatoLocal_Shutdown($h);
is(scalar(grep { /TestMode Off/i } @WRITTEN), 1, "shutdown leaves test mode");
is($h->{helper}{testMode}, 0, "test mode flag cleared");
