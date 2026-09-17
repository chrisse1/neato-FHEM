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
use Test::More tests => 84;

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

# A healthy D6 fills both sections with code 200 / UI_ALERT_INVALID, which
# means "nothing here" -- captured from a working robot, not invented.
NeatoLocal_ParseErr($h, { cmd => "GetErr" },
    "Error\r\n200 -  (UI_ALERT_INVALID)\r\nAlert\r\n200 -  (UI_ALERT_INVALID)\r\n"
  . "USB state \r\n NOT connected\r\n");
is(ReadingsVal("nt", "errorCode", ""), 0, "UI_ALERT_INVALID is not an error");
is(ReadingsVal("nt", "error", ""), "none", "empty error slot reads as none");
is(ReadingsVal("nt", "alertCode", ""), 0, "UI_ALERT_INVALID is not an alert either");
isnt(ReadingsVal("nt", "state", ""), "error", "a healthy robot is not in the error state");

# but a real fault still gets through
NeatoLocal_ParseErr($h, { cmd => "GetErr" },
    "Error\r\n249 -  (UI_ERROR_DUST_BIN_MISSING)\r\nAlert\r\n200 -  (UI_ALERT_INVALID)\r\n");
is(ReadingsVal("nt", "errorCode", ""), "249", "a real error is still reported");
is(ReadingsVal("nt", "alertCode", ""), 0, "the empty alert slot stays empty");
is(ReadingsVal("nt", "state", ""), "error", "a real error still sets the state");

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

# --- the event key -----------------------------------------------------------
# These three values were produced by OpenNeato's C++ computeSKey and this Perl
# reimplementation must keep matching them exactly -- the robot rejects the
# event otherwise.
is(NeatoLocal_ComputeSKey("GPC33719,40bd32d1097a,P"), "b60fcdadd92e3d1418da0608a",
   "SKey matches the reference implementation (real robot's MAC)");
is(NeatoLocal_ComputeSKey("KSH12345,aabbccddeeff,P"), "e35ecdab897f3d414d86570fa",
   "SKey matches the reference implementation (second vector)");
is(NeatoLocal_ComputeSKey("X,000000000000,X"), "b20f9ff9da2c691518d30159f",
   "SKey matches the reference implementation (third vector)");
is(length(NeatoLocal_ComputeSKey("X,000000000000,X")), 25, "SKey is 25 characters");

is(NeatoLocal_ComputeSKey("GPC33719"), "", "a serial without a MAC yields no key");
is(NeatoLocal_ComputeSKey("GPC33719,tooshort,P"), "", "a short MAC yields no key");
is(NeatoLocal_ComputeSKey(undef), "", "an undefined serial yields no key");

# GetVersion has to keep the MAC, not just the serial
is($h->{helper}{skey}, "b60fcdadd92e3d1418da0608a",
   "the key is derived while parsing GetVersion");
is(ReadingsVal("nt", "commandApi", ""), "setEvent", "the event API is reported as available");

# --- command mapping ---------------------------------------------------------
$attr{"nt"}{disable} = 0;
my ($mapped, $err) = NeatoLocal_MappedCmd($h, "sendToBase");
is($mapped, "SetEvent event UIMGR_EVENT_SMARTAPP_SEND_TO_BASE SKey b60fcdadd92e3d1418da0608a",
   "sendToBase uses the event API");
is($err, undef, "sendToBase needs no manual configuration");

($mapped, $err) = NeatoLocal_MappedCmd($h, "pause");
like($mapped, qr/^SetEvent event UIMGR_EVENT_SMARTAPP_PAUSE_CLEANING SKey /,
     "pause prefers the event over the simulated button");

# explore has no event, so it stays on the documented command
($mapped, $err) = NeatoLocal_MappedCmd($h, "explore");
is($mapped, "Clean Explore", "commands without an event use the documented one");

($mapped, $err) = NeatoLocal_MappedCmd($h, "findMe");
is($mapped, "PlaySound SoundID 20", "findMe plays the Find Me sound");

# turning the event API off falls back to what the Help output documents
$attr{"nt"}{useSetEvent} = 0;
($mapped, $err) = NeatoLocal_MappedCmd($h, "pause");
is($mapped, "SetButton start", "useSetEvent 0 falls back to the button press");
($mapped, $err) = NeatoLocal_MappedCmd($h, "sendToBase");
is($mapped, undef, "without the event API there is no way to send the robot home");
like($err, qr/event API/, "and the reason says so");
delete $attr{"nt"}{useSetEvent};

# an attribute always wins
$attr{"nt"}{cmdSendToBase} = "SetButton back";
($mapped, $err) = NeatoLocal_MappedCmd($h, "sendToBase");
is($mapped, "SetButton back", "an attribute overrides even the event API");
delete $attr{"nt"}{cmdSendToBase};

# a robot that never gave us a MAC
my $savedKey = $h->{helper}{skey};
$h->{helper}{skey} = "";
($mapped, $err) = NeatoLocal_MappedCmd($h, "stop");
is($mapped, "Clean Stop", "older firmware still gets the documented command");
$h->{helper}{skey} = $savedKey;

($mapped, $err) = NeatoLocal_MappedCmd($h, "nonsense");
like($err, qr/unknown command/, "an unknown mapping is rejected");

# --- the robot's own state beats guessing from the motor ---------------------
NeatoLocal_ParseState($h, { cmd => "GetState" },
    "Current UI State is: UIMGR_STATE_STANDBY\r\nCurrent Robot State is: ST_C_Standby\r\n");
is(ReadingsVal("nt", "uiState", ""), "UIMGR_STATE_STANDBY", "UI state parsed");
is(ReadingsVal("nt", "robotState", ""), "ST_C_Standby", "robot state parsed");
is(NeatoLocal_StateIsIdle($h), 1, "standby counts as idle");

NeatoLocal_ParseState($h, { cmd => "GetState" },
    "Current UI State is: UIMGR_STATE_CLEANINGPAUSED\r\nCurrent Robot State is: ST_C_Paused\r\n");
is(ReadingsVal("nt", "state", ""), "paused", "a paused cleaning is reported as paused");

NeatoLocal_ParseState($h, { cmd => "GetState" },
    "Current UI State is: UIMGR_STATE_STARTHOUSECLEANING\r\nCurrent Robot State is: ST_C_Cleaning\r\n");
is(ReadingsVal("nt", "state", ""), "cleaning", "an active cleaning is reported as cleaning");

NeatoLocal_ParseState($h, { cmd => "GetState" },
    "Current UI State is: UIMGR_STATE_DOCKING\r\nCurrent Robot State is: ST_C_GoingHome\r\n");
is(ReadingsVal("nt", "state", ""), "docking", "the way home is reported as docking");

# the UI state can lag behind; the robot state decides
NeatoLocal_ParseState($h, { cmd => "GetState" },
    "Current UI State is: UIMGR_STATE_STARTHOUSECLEANING\r\nCurrent Robot State is: ST_C_Standby\r\n");
is(NeatoLocal_StateIsIdle($h), 1, "a stale UI state does not keep it cleaning");
isnt(ReadingsVal("nt", "state", ""), "cleaning", "and the state follows the robot, not the UI");

NeatoLocal_ParseState($h, { cmd => "GetState" }, "nothing useful here");
is(ReadingsVal("nt", "uiState", ""), "UIMGR_STATE_STARTHOUSECLEANING",
   "an unparseable answer leaves the last state alone");

# --- a silent robot must not flood the log or pile up the queue -------------
# This is the state of things while the bridge is wired up but the robot is not
# connected to it yet.
($h, $ret) = mkdev("nt NeatoLocal 192.168.1.42:23");
$attr{"nt"}{interval} = 60;
$h->{helper}{failCount} = 0;

is(NeatoLocal_PollInterval($h), 60, "healthy device polls at the configured interval");

$h->{helper}{failCount} = 1;
is(NeatoLocal_PollInterval($h), 60, "a single timeout does not slow polling yet");

$h->{helper}{failCount} = 2;
is(NeatoLocal_PollInterval($h), 120, "repeated timeouts back off");
$h->{helper}{failCount} = 4;
is(NeatoLocal_PollInterval($h), 480, "backoff grows with the failure count");
$h->{helper}{failCount} = 99;
is(NeatoLocal_PollInterval($h), 960, "backoff stops growing at 16x");

$attr{"nt"}{interval} = 900;
$h->{helper}{failCount} = 99;
is(NeatoLocal_PollInterval($h), 3600, "backoff is capped at an hour");
$attr{"nt"}{interval} = 60;

# a timeout counts, and after three of them the device says so
$h->{helper}{failCount} = 0;
$h->{helper}{queue} = [];
foreach my $i (1 .. 3) {
    $h->{helper}{pending} = { cmd => "GetCharger" };
    NeatoLocal_Timeout($h);
}
is($h->{helper}{failCount}, 3, "consecutive timeouts are counted");
is(ReadingsVal("nt", "state", ""), "unreachable", "a silent robot is reported as unreachable");

# a status request must not stack a second set of queries on a stuck one
$h->{helper}{queue} = [];
$h->{helper}{pending} = { cmd => "GetCharger" };
NeatoLocal_StatusRequest($h);
is(scalar(@{$h->{helper}{queue}}), 0, "no new queries while one is still pending");
delete $h->{helper}{pending};

# and one answer puts everything back to normal
NeatoLocal_Dispatch($h, "GetCharger\r\nFuelPercent,68\r\nExtPwrPresent,1\r\n",
                    { cmd => "GetCharger", parser => \&NeatoLocal_ParseCharger });
is($h->{helper}{failCount}, 0, "a response clears the failure count");
is(NeatoLocal_PollInterval($h), 60, "polling returns to the configured interval");
isnt(ReadingsVal("nt", "state", ""), "unreachable", "state recovers with the robot");

# --- test mode must always be left again -----------------------------------
$h->{helper}{testMode} = 1;
@WRITTEN = ();
NeatoLocal_Shutdown($h);
is(scalar(grep { /TestMode Off/i } @WRITTEN), 1, "shutdown leaves test mode");
is($h->{helper}{testMode}, 0, "test mode flag cleared");
