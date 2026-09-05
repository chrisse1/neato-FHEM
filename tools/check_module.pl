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
use Test::More tests => 43;

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
# Every fixture below is verbatim console output of a BotVac D6 Connected
# running software 4.5.3.189, captured with tools/dump_robot.py.
# See docs/reference-dump-botvac-d6.txt.
my $raw = "GetCharger\r\nLabel,Value\r\nFuelPercent,68\r\nBatteryOverTemp,0\r\n"
        . "ChargingActive,0\r\nChargingEnabled,1\r\nConfidentOnFuel,0\r\n"
        . "OnReservedFuel,0\r\nEmptyFuel,0\r\nBatteryFailure,0\r\n"
        . "ExtPwrPresent,0\r\nThermistorPresent,1\r\nBattTempCAvg,27\r\n"
        . "VBattV,15.90\r\nVExtV,0.00\r\nCharger_mAH,0\r\nDischarge_mAH,149\r\n"
        . chr(26);
my $body = NeatoLocal_StripEcho("GetCharger", $raw);
unlike($body, qr/GetCharger/, "echoed command is stripped");
unlike($body, qr/\x1a/, "response terminator is stripped");

my $csv = NeatoLocal_ParseCsv($body);
is($csv->{FuelPercent}, "68", "CSV value parsed");
is($csv->{VBattV}, "15.90", "float CSV value parsed");

# --- parsers ---------------------------------------------------------------
($h, $ret) = mkdev("nt NeatoLocal /dev/ttyACM0");
NeatoLocal_ParseCharger($h, { cmd => "GetCharger" }, $body);
is(ReadingsVal("nt", "batteryPercent", ""), "68", "batteryPercent reading set");
is(ReadingsVal("nt", "isDocked", ""), 0, "isDocked derived from ExtPwrPresent");
is(ReadingsVal("nt", "isCharging", ""), 0, "isCharging derived from ChargingActive");
is(ReadingsVal("nt", "state", ""), "idle", "off the base and not cleaning is idle");

# The D-series answers in sections. An alert must not become an error.
my $errOut = "Error\r\n249 -  (UI_ERROR_DUST_BIN_MISSING)\r\n"
           . "Alert\r\n248 -  (UI_ERROR_DUST_BIN_EMPTIED)\r\n"
           . "USB state \r\n NOT connected\r\n";
NeatoLocal_ParseErr($h, { cmd => "GetErr" }, $errOut);
is(ReadingsVal("nt", "errorCode", ""), "249", "error code taken from the Error section");
is(ReadingsVal("nt", "error", ""), "UI_ERROR_DUST_BIN_MISSING", "error text unwrapped");
is(ReadingsVal("nt", "alertCode", ""), "248", "alert code taken from the Alert section");
is(ReadingsVal("nt", "alert", ""), "UI_ERROR_DUST_BIN_EMPTIED", "alert text unwrapped");
is(ReadingsVal("nt", "usbConnected", ""), 0, "USB state parsed");
is(ReadingsVal("nt", "state", ""), "error", "state switches to error");

# an alert on its own is not an error
NeatoLocal_ParseErr($h, { cmd => "GetErr" },
    "Error\r\nAlert\r\n248 -  (UI_ERROR_DUST_BIN_EMPTIED)\r\n");
is(ReadingsVal("nt", "errorCode", ""), 0, "alert alone leaves errorCode at 0");
is(ReadingsVal("nt", "alertCode", ""), "248", "alert alone is still reported");
isnt(ReadingsVal("nt", "state", ""), "error", "alert alone does not force the error state");

# older firmware prints the bare code line with no section header
NeatoLocal_ParseErr($h, { cmd => "GetErr" }, "220 - Please put my Dirt Bin back in.");
is(ReadingsVal("nt", "errorCode", ""), "220", "headerless output still parses as an error");

NeatoLocal_ParseErr($h, { cmd => "GetErr" }, "");
is(ReadingsVal("nt", "error", ""), "none", "cleared error resets the reading");

NeatoLocal_ParseMotors($h, { cmd => "GetMotors" },
    "Parameter,Value\r\nBrush_RPM,1400\r\nBrush_mA,0\r\nVacuum_RPM,2100\r\n"
  . "Vacuum_mA,0\r\nLeftWheel_RPM,0\r\nROTATION_SPEED,0.00\r\nSideBrush_mA,0\r\n");
is(ReadingsVal("nt", "isCleaning", ""), 1, "cleaning detected from Vacuum_RPM");

NeatoLocal_ParseMotors($h, { cmd => "GetMotors" },
    "Parameter,Value\r\nBrush_RPM,0\r\nVacuum_RPM,0\r\nROTATION_SPEED,0.00\r\n");
is(ReadingsVal("nt", "isCleaning", ""), 0, "idle motors clear the cleaning flag");

# GetVersion spreads values over a varying number of columns
NeatoLocal_ParseVersion($h, { cmd => "GetVersion" },
    "Component,Major,Minor,Build,Aux\r\nBaseID,0.0,0.0,0,0,\r\n"
  . "Beehive URL, beehive.neatocloud.com,\r\nBrushSpeed,1400,,\r\n"
  . "LDS Software,V2.7.4,0000000000,\r\n"
  . "MainBoard Version,4,,\r\nModel,BotVacD6Connected,905-0496,\r\n"
  . "Serial Number,GPC26519-0000123,40bd32d1097a,P\r\n"
  . "Software Git SHA,14f004c\r\nSoftware,4,5,3,189,0\r\n");
is(ReadingsVal("nt", "model", ""), "BotVacD6Connected", "model taken from the Model row");
is(ReadingsVal("nt", "serialNumber", ""), "GPC26519-0000123", "serial number parsed");
is(ReadingsVal("nt", "firmware", ""), "4.5.3.189.0", "version columns joined");
is(ReadingsVal("nt", "ldsSoftware", ""), "V2.7.4", "lidar software parsed");

# --- verified command mapping ----------------------------------------------
$attr{"nt"}{disable} = 0;
my ($mapped, $err) = NeatoLocal_MappedCmd($h, "sendToBase");
is($mapped, "SetButton IRhome", "sendToBase maps to the home button");
is($err, undef, "sendToBase no longer needs manual configuration");

($mapped, $err) = NeatoLocal_MappedCmd($h, "findMe");
is($mapped, "PlaySound SoundID 20", "findMe plays the Find Me sound");

# an attribute still wins over the built-in default
$attr{"nt"}{cmdSendToBase} = "SetButton back";
($mapped, $err) = NeatoLocal_MappedCmd($h, "sendToBase");
is($mapped, "SetButton back", "attribute overrides the default command");
delete $attr{"nt"}{cmdSendToBase};

# --- an emptied mapping must fail loudly, not silently ---------------------
$attr{"nt"}{cmdSendToBase} = "";
($mapped, $err) = NeatoLocal_MappedCmd($h, "sendToBase");
is($mapped, undef, "an emptied command is not sent");
like($err, qr/cmdSendToBase/, "an unconfigured command points at its attribute");
delete $attr{"nt"}{cmdSendToBase};

($mapped, $err) = NeatoLocal_MappedCmd($h, "nonsense");
like($err, qr/unknown command/, "an unknown mapping is rejected");

# --- test mode must always be left again -----------------------------------
$h->{helper}{testMode} = 1;
@WRITTEN = ();
NeatoLocal_Shutdown($h);
is(scalar(grep { /TestMode Off/i } @WRITTEN), 1, "shutdown leaves test mode");
is($h->{helper}{testMode}, 0, "test mode flag cleared");
