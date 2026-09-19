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
use Test::More tests => 260;

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

our @BLOCKING;
sub BlockingCall          { push @BLOCKING, [@_]; return { }; }

our @MODIFIED;
sub CommandModify         { push @MODIFIED, $_[1]; return undef; }
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
    my ($name) = split(" ", $def);          # FHEM names the device in the DEF
    my $hash = { NAME => $name, STATE => "opened" };
    $defs{$name} = $hash;
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

# an address of "none" is the written-out form of leaving it off
($h, $ret) = mkdev("nt NeatoLocal none");
is($h->{TRANSPORT}, "none", "the literal none means no address either");

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

# Captured from a robot that ran out of battery on its way back to the base:
# it suspends the run, intends to charge and resume, and is anything but
# cleaning. A substring match on CLEAN used to report it as cleaning.
NeatoLocal_ParseState($h, { cmd => "GetState" },
    "Current UI State is: UIMGR_STATE_CLEANINGSUSPENDED\r\n"
  . "Current Robot State is: ST_M1_Charging_Cleaning\r\n");
is(ReadingsVal("nt", "state", ""), "suspended",
   "a run the robot suspended itself is not reported as cleaning");
is(ReadingsVal("nt", "robotState", ""), "ST_M1_Charging_Cleaning",
   "and the robot state is kept verbatim");

# a completed run must not read as cleaning either
NeatoLocal_ParseState($h, { cmd => "GetState" },
    "Current UI State is: UIMGR_STATE_CLEANINGCOMPLETE\r\n"
  . "Current Robot State is: ST_C_Standby\r\n");
isnt(ReadingsVal("nt", "state", ""), "cleaning", "a finished run is not cleaning");

NeatoLocal_ParseState($h, { cmd => "GetState" }, "nothing useful here");
is(ReadingsVal("nt", "uiState", ""), "UIMGR_STATE_CLEANINGCOMPLETE",
   "an unparseable answer leaves the last state alone");

# --- finding the right serial port -------------------------------------------
# Both an ESP32-C3 and the robot appear as /dev/ttyACM*, so the bare number
# says nothing. The by-id names do, and they are what this has to surface.
{
    my $root = "/tmp/.neato_ports";
    system("rm -rf $root; mkdir -p $root/byid $root/dev");
    system("touch $root/dev/ttyACM0 $root/dev/ttyACM1 $root/dev/ttyUSB0 $root/dev/random");
    symlink("../../ttyACM0", "$root/byid/usb-Espressif_USB_JTAG_serial_debug_unit_AA-if00");
    symlink("../../ttyACM1", "$root/byid/usb-Neato_Robotics_Botvac-if00");
    symlink("../../ttyUSB0", "$root/byid/usb-1a86_USB_Serial-if00-port0");

    my $ports = NeatoLocal_ScanSerialPorts("$root/byid", "$root/dev");
    is(scalar(@$ports), 3, "every port is listed once");

    my %by = map { $_->{port} => $_ } @$ports;
    is($by{"$root/dev/ttyACM0"}{what}, "ESP32 (native USB)", "the C3 is recognised");
    is($by{"$root/dev/ttyACM1"}{what}, "Neato robot", "the robot is recognised");
    is($by{"$root/dev/ttyUSB0"}{what}, "USB-serial adapter", "a CH340 adapter is recognised");
    like($by{"$root/dev/ttyACM0"}{id}, qr/Espressif/, "the stable name is reported");

    # a port without a by-id entry must not disappear
    symlink("nowhere", "$root/byid/broken") if (0);
    unlink("$root/byid/usb-Neato_Robotics_Botvac-if00");
    $ports = NeatoLocal_ScanSerialPorts("$root/byid", "$root/dev");
    %by = map { $_->{port} => $_ } @$ports;
    is($by{"$root/dev/ttyACM1"}{what}, "unknown", "a port without a by-id entry is still listed");
    is($by{"$root/dev/ttyACM1"}{id}, "-", "and says it has no stable name");
    ok(!exists($by{"$root/dev/random"}), "files that are not serial ports are ignored");

    my $text = NeatoLocal_FormatSerialPorts($ports);
    like($text, qr/ttyACM0/, "the listing names the ports");
    like($text, qr/by-id/, "and points at the stable names");

    like(NeatoLocal_FormatSerialPorts([]), qr/charge-only cable/,
         "an empty machine gets a useful hint instead of a blank answer");

    system("rm -rf $root");
}

# --- a device may exist before its bridge does --------------------------------
# Otherwise there is no way in: flashESP needs a device, and a device would
# need the address of a bridge that has not been flashed yet.
{
    my ($uh, $ur) = mkdev("un NeatoLocal");
    is($ur, undef, "a define without an address is accepted");
    is($uh->{TRANSPORT}, "none", "and leaves the transport open");
    is(ReadingsVal("un", "state", ""), "unconfigured", "the state says so");
    is($uh->{DeviceName}, undef, "nothing is opened");

    like(NeatoLocal_Enqueue($uh, "GetVersion"), qr/flash the bridge first/,
         "talking to the robot is refused with a hint");
    is(NeatoLocal_Init($uh), undef, "initialising does nothing");
    is(NeatoLocal_Ready($uh), undef, "and no connection is attempted");

    # provisioning reports where the bridge came up -- that is the address
    @MODIFIED = ();
    $uh->{helper}{flashRunning} = 1;
    NeatoLocal_ProvisionDone("un|OK|192.168.1.57");
    is($MODIFIED[0], "un 192.168.1.57:23", "the device points itself at the bridge");
    is(ReadingsVal("un", "bridgeAddress", ""), "192.168.1.57", "and records it");

    # a device that already has an address keeps it
    my ($ch, $cr) = mkdev("cfg NeatoLocal 192.168.1.42:23");
    @MODIFIED = ();
    $ch->{helper}{flashRunning} = 1;
    NeatoLocal_ProvisionDone("cfg|OK|192.168.1.99");
    is(scalar(@MODIFIED), 0, "a configured device is not silently repointed");
    is(ReadingsVal("cfg", "bridgeAddress", ""), "192.168.1.99",
       "though the new address is still reported");

    # anything that is not an address must not end up in the definition
    @MODIFIED = ();
    $uh->{TRANSPORT} = "none";
    $uh->{helper}{flashRunning} = 1;
    NeatoLocal_ProvisionDone("un|OK|no answer from the board");
    is(scalar(@MODIFIED), 0, "a reply without an address changes no definition");

    like(NeatoLocal_Define($uh, "un NeatoLocal a b c"), qr/Usage/,
         "too many arguments are still rejected");

    delete $defs{"un"};
    delete $defs{"cfg"};
}

# --- flashing the bridge -----------------------------------------------------
# The work happens in a forked child, so the set only has to hand over the
# right arguments -- and refuse when it cannot.
{
    my ($fh, $fr) = mkdev("fl NeatoLocal 192.168.1.42:23");
    $attr{"fl"}{espPort} = "/dev/ttyACM9";
    @BLOCKING = ();

    # No image named: the one this project builds is the sensible default, so
    # nothing has to be downloaded by hand before a board can be flashed.
    NeatoLocal_Set($fh, "fl", "flashESP");
    is(scalar(@BLOCKING), 1, "flashESP without an image falls back to the built one");
    like($BLOCKING[0][1], qr{\|https://[^|]*neato_bridge-esp32c3\.bin\|},
         "and that is the image CI publishes");
    delete $defs{"fl"}{helper}{flashRunning};
    @BLOCKING = ();

    NeatoLocal_Set($fh, "fl", "flashESP", "/tmp/neato.bin");
    is(scalar(@BLOCKING), 1, "flashESP runs in the background");
    is($BLOCKING[0][0], "NeatoLocal_FlashBlocking", "with the flashing worker");
    is($BLOCKING[0][1], "fl|/dev/ttyACM9|/tmp/neato.bin||",
       "and is told device, port and image");
    is(ReadingsVal("fl", "lastFlash", ""), "running", "the run is visible as a reading");

    like(NeatoLocal_Set($fh, "fl", "flashESP", "/tmp/neato.bin"),
         qr/has been going for/,
         "a second run is refused while one is going");

    # A run that was killed must not lock the device for good: there is no way
    # back from that except restarting FHEM.
    @BLOCKING = ();
    $fh->{helper}{flashRunning} = time() - 3600;
    NeatoLocal_Set($fh, "fl", "flashESP", "/tmp/neato.bin");
    is(scalar(@BLOCKING), 1, "a lock left behind by a killed run is not permanent");

    delete $fh->{helper}{flashRunning};
    @BLOCKING = ();

    NeatoLocal_Set($fh, "fl", "wifiESP", "MeinWLAN", "geheim");
    is($BLOCKING[0][1], "fl|/dev/ttyACM9|MeinWLAN|geheim",
       "ssid and password are passed on");
    is($BLOCKING[0][0], "NeatoLocal_ProvisionBlocking", "with the provisioning worker");

    # both may contain spaces, which is what the quotes are for
    delete $fh->{helper}{flashRunning};
    @BLOCKING = ();
    NeatoLocal_Set($fh, "fl", "wifiESP", '"Mein', 'WLAN"', '"lange', 'Passphrase"');
    is($BLOCKING[0][1], "fl|/dev/ttyACM9|Mein WLAN|lange Passphrase",
       "quoted values survive the split FHEM already did");

    delete $fh->{helper}{flashRunning};
    like(NeatoLocal_Set($fh, "fl", "wifiESP"), qr/usage/, "wifiESP needs arguments");

    # the results have to land in readings. The address field sits before the
    # tool output, which may itself contain the separator.
    $fh->{helper}{flashRunning} = 1;
    NeatoLocal_FlashDone("fl|OK||Hash of data verified");
    is(ReadingsVal("fl", "lastFlash", ""), "ok", "a successful flash is recorded");
    is($fh->{helper}{flashRunning}, undef, "and the run is marked finished");

    # Flashed with credentials: the board is asked where it ended up, because a
    # bridge on the network that the module cannot address is no use.
    $fh->{helper}{flashRunning} = 1;
    NeatoLocal_FlashDone("fl|OK|192.168.1.61|Hash of data verified | Leaving...");
    is(ReadingsVal("fl", "bridgeAddress", ""), "192.168.1.61",
       "flashing with credentials reports the address too");
    like(ReadingsVal("fl", "lastFlash", ""), qr/ok, bridge at 192\.168\.1\.61/,
         "and says so rather than just 'ok'");
    readingsSingleUpdate($fh, "bridgeAddress", "", 1);

    # the failure messages have to say what to do, not just that it failed
    NeatoLocal_ProvisionDone("fl|credentials stored, but the board could not "
                           . "join the network -- it opened the setup access "
                           . "point instead.");
    like(ReadingsVal("fl", "lastFlash", ""), qr/wifi: credentials stored/,
         "a board that saved but could not join says so");
    is(ReadingsVal("fl", "bridgeAddress", ""), "",
       "and no address is recorded for it");

    $fh->{helper}{flashRunning} = 1;
    NeatoLocal_ProvisionDone("fl|OK|192.168.1.57");
    is(ReadingsVal("fl", "bridgeAddress", ""), "192.168.1.57",
       "provisioning reports the address the bridge took");

    # Both routes into the module share one way of adopting an address, so a
    # device defined without one ends up pointed at the bridge either way.
    {
        my ($uh, $ur) = mkdev("un2 NeatoLocal");
        @MODIFIED = ();
        NeatoLocal_FlashDone("un2|OK|192.168.1.62|written");
        is(scalar(@MODIFIED), 1, "flashing points an unconfigured device at the bridge");
        is($MODIFIED[0], "un2 192.168.1.62:23", "with the address the board reported");

        my ($ch, $cr) = mkdev("cfg2 NeatoLocal 192.168.1.5:23");
        @MODIFIED = ();
        NeatoLocal_FlashDone("cfg2|OK|192.168.1.63|written");
        is(scalar(@MODIFIED), 0, "a device that has an address keeps it");
    }

    NeatoLocal_FlashDone("fl|failed (rc 2)||A fatal error occurred");
    like(ReadingsVal("fl", "lastFlash", ""), qr/fatal/, "a failure keeps its reason");

    # nothing that is not a firmware image may reach the board
    my $tmp = "/tmp/.neato_check_image";
    is(NeatoLocal_CheckImage("$tmp.missing"), "image not readable: $tmp.missing",
       "a missing image is refused");

    open(my $th, ">", $tmp); close($th);
    like(NeatoLocal_CheckImage($tmp), qr/empty/, "an empty file is refused");

    open($th, ">", $tmp); print $th "<html>404: Not Found</html>"; close($th);
    like(NeatoLocal_CheckImage($tmp), qr/far too small/,
         "an error page instead of an image is refused");

    open($th, ">", $tmp); binmode($th);
    print $th "\x00" x 200000; close($th);
    like(NeatoLocal_CheckImage($tmp), qr/0xE9/,
         "a file of the right size but without the magic is refused");

    open($th, ">", $tmp); binmode($th);
    print $th "\xE9" . ("\x00" x 200000); close($th);
    is(NeatoLocal_CheckImage($tmp), undef, "a plausible image passes");
    unlink($tmp);

    delete $attr{"fl"};
    delete $defs{"fl"};
}

# --- an unreachable bridge must not stall FHEM for long ----------------------
# FHEM opens TCP connections synchronously; DevIo's default of 3 seconds is
# long enough to be felt, and the bridge vanishes whenever the robot is off.
my ($ht, $hr) = mkdev("nt2 NeatoLocal 192.168.1.42:23");
is($ht->{TIMEOUT}, 2, "a TCP device bounds the connect timeout");

$attr{"nt2"}{connectTimeout} = 5;
($ht, $hr) = mkdev("nt2 NeatoLocal 192.168.1.42:23");
is($ht->{TIMEOUT}, 5, "the attribute raises it");

is(NeatoLocal_Attr("set", "nt2", "connectTimeout", "4"), undef, "a sane value is accepted");
is($defs{"nt2"}{TIMEOUT}, 4, "and takes effect at once");
like(NeatoLocal_Attr("set", "nt2", "connectTimeout", "99"), qr/between/,
     "an absurd value is rejected");
NeatoLocal_Attr("del", "nt2", "connectTimeout", undef);
is($defs{"nt2"}{TIMEOUT}, 2, "deleting it restores the default");
delete $attr{"nt2"};
delete $defs{"nt2"};

# --- answers must not break FHEMWEB ------------------------------------------
# FHEMWEB pastes the answer into FW_okDialog('...'). A raw line break in there
# is a JavaScript syntax error and the dialog stays empty, which is what a
# multi-line console answer used to cause.
my $safe = NeatoLocal_WebSafe("Label,Value\r\nDesign Capacity mA,4200\n");
unlike($safe, qr/[\r\n]/, "no line breaks survive into the JavaScript string");
like($safe, qr/<br>/, "line breaks become HTML instead");
like($safe, qr/^<html>.*<\/html>$/, "the answer is marked up as HTML");

$safe = NeatoLocal_WebSafe("it's a \\ backslash and <tag> & ampersand");
unlike($safe, qr/'/, "quotes cannot terminate the string literal");
unlike($safe, qr/\\/, "backslashes cannot escape anything");
like($safe, qr/&#39;/, "the quote survives as an entity");
like($safe, qr/&lt;tag&gt;/, "markup in the answer is not interpreted");
like($safe, qr/&amp; ampersand/, "the ampersand is escaped once, not twice");

is(NeatoLocal_WebSafe(undef), "<html></html>", "an undefined answer is handled");

# --- battery health ----------------------------------------------------------
# Verbatim "GetCharger data" of a worn out D6 pack, and "GetCharger info" for
# the design capacity it does not carry itself.
NeatoLocal_ParseBattery($h, { cmd => "GetCharger info" },
    "Label,Value\r\nManufacturer Name, Panasonic\r\nDevice Chemistry, LION1\r\n"
  . "Capacity Mode, mA\r\nDesign Capacity mA,4200\r\nDesign Voltage,14400\r\n"
  . "Full Charge Capacity mA,764\r\n");
is(ReadingsVal("nt", "batteryCapacityDesign", ""), "4200", "design capacity parsed");

NeatoLocal_ParseBattery($h, { cmd => "GetCharger data" },
    "Label,Value\r\nVoltage mV,15272\r\nCurrent mA,1987\r\n"
  . "Temperature deciC,26600\r\nRelative State of Charge( batt_full% ),10\r\n"
  . "Remaining Capacity mA,76\r\nFull Charge Capacity mA,764\r\n"
  . "Cycle Count,1484\r\nStatus,640\r\nREMAINING_CAPACITY_ALARM,1\r\nError,0\r\n");
is(ReadingsVal("nt", "batteryCapacityFull", ""), "764", "full charge capacity parsed");
is(ReadingsVal("nt", "batteryHealth", ""), "18", "state of health computed from both");
is(ReadingsVal("nt", "batteryCycles", ""), "1484", "the pack's own cycle count wins");
is(ReadingsVal("nt", "batteryTemperature", ""), "26.6",
   "temperature read as milli-degrees despite the deciC label");

# a healthy pack
NeatoLocal_ParseBattery($h, { cmd => "GetCharger data" },
    "Full Charge Capacity mA,4100\r\nCycle Count,12\r\n");
is(ReadingsVal("nt", "batteryHealth", ""), "98", "a fresh pack reports near full health");

# an answer without the capacity must not produce a bogus health figure
NeatoLocal_ParseBattery($h, { cmd => "GetCharger data" }, "Voltage mV,15272\r\n");
is(ReadingsVal("nt", "batteryHealth", ""), "98", "an incomplete answer changes nothing");

# --- lifetime counters -------------------------------------------------------
# Verbatim GetWarranty output of the D6. The values are hex: the validation
# code beside them could not be anything else, and 05c2 is not a decimal number.
NeatoLocal_ParseWarranty($h, { cmd => "GetWarranty" },
    "Item,Value\r\nCumulativeCleaningTimeInSecs,00192364\r\n"
  . "CumulativeBatteryCycles,05c2\r\nValidationCode,c2cc3e78\r\n");
is(ReadingsVal("nt", "batteryCycles", ""), 1474, "battery cycles decoded from hex");
is(ReadingsVal("nt", "cleaningHours", ""), "457.6", "cleaning time converted to hours");

NeatoLocal_ParseWarranty($h, { cmd => "GetWarranty" }, "Item,Value\r\n");
is(ReadingsVal("nt", "batteryCycles", ""), 1474, "an empty answer keeps the counters");

# --- the version has to survive a reload -------------------------------------
# Define runs once, so an existing device would otherwise keep reporting the
# version it was defined with.
$h->{VERSION} = "0.0.1";
NeatoLocal_Poll($h);
isnt($h->{VERSION}, "0.0.1", "polling refreshes the reported version");

# --- user settings -----------------------------------------------------------
# Verbatim GetUserSettings output of a BotVac D6 Connected, including the
# trailing spaces and the garbled schedule lines.
my $settings = "Language, EL_NONE \r\nClickSounds, ON \r\nLED, ON \r\n"
             . "Wall Enable, ON \r\nEco Mode, OFF \r\nIntenseClean, OFF \r\n"
             . "WiFi, OFF \r\nMelody Sounds, ON \r\nWarning Sounds, ON \r\n"
             . "Bin Full Detect, ON \r\nFilter Change Time (seconds), 43200 \r\n"
             . "Brush Change Time (seconds), 259200 \r\n"
             . "Dirt Bin Alert Reminder Interval (minutes), 90 \r\n"
             . "Current Dirt Bin Runtime is: 0\r\n"
             . "Number of Cleanings where Dust Bin was Full is: 0\r\n"
             . "Schedule is Disabled\r\n"
             . "\xef\xbf\xbd' 00:00 -None-\r\n"
             . "\xef\xbf\xbd' 00:00 -None-\r\n";

NeatoLocal_ParseUserSettings($h, { cmd => "GetUserSettings" }, $settings);
is(ReadingsVal("nt", "ecoMode", ""), "off", "eco mode parsed and lowercased");
is(ReadingsVal("nt", "intenseClean", ""), "off", "intense clean parsed");
is(ReadingsVal("nt", "binFullDetect", ""), "on", "bin full detect parsed");
is(ReadingsVal("nt", "wifiEnabled", ""), "off", "wifi state parsed");
is(ReadingsVal("nt", "filterChangeTime", ""), "43200", "numeric setting kept as is");
is(ReadingsVal("nt", "dirtBinInterval", ""), "90", "key with parentheses parsed");
is(ReadingsVal("nt", "scheduleEnabled", ""), 0, "schedule state parsed from its own line");
is(ReadingsVal("nt", "scheduledCleanings", ""), 0, "empty schedule slots are not counted");

# a filled schedule slot has to count
NeatoLocal_ParseUserSettings($h, { cmd => "GetUserSettings" },
    "Schedule is Enabled\r\nMon 09:30 House\r\nTue 00:00 -None-\r\n");
is(ReadingsVal("nt", "scheduleEnabled", ""), 1, "an enabled schedule is reported");
is(ReadingsVal("nt", "scheduledCleanings", ""), 1, "a filled slot is counted");

# the colon lines carry no setting and must not create readings
NeatoLocal_ParseUserSettings($h, { cmd => "GetUserSettings" },
    "Current Dirt Bin Runtime is: 42\r\n");
is(ReadingsVal("nt", "language", ""), "EL_NONE", "an unrelated line changes nothing");

# --- setting a user setting reads it back ------------------------------------
$h->{STATE} = "opened";
$h->{helper}{pending} = { cmd => "busy" };
$h->{helper}{queue} = [];

NeatoLocal_Set($h, "nt", "ecoMode", "ON");
is($h->{helper}{queue}[0]{cmd}, "SetUserSettings EcoMode ON", "eco mode is set on the robot");
is($h->{helper}{queue}[1]{cmd}, "GetUserSettings", "and read back afterwards");

$h->{helper}{queue} = [];
like(NeatoLocal_Set($h, "nt", "intenseClean", "vielleicht"), qr/usage/,
     "only on and off are accepted");
is(scalar(@{$h->{helper}{queue}}), 0, "and nothing is sent for a bad argument");

$h->{helper}{queue} = [];
delete $h->{helper}{pending};

# --- the navigation mode -----------------------------------------------------
# The console offers no way to read it back, so the reading holds what FHEM set
# and has to be re-applied before each house cleaning.
$h->{STATE} = "opened";
# a command already in flight keeps the queue from draining while we inspect it
$h->{helper}{pending} = { cmd => "busy" };
$h->{helper}{queue} = [];

NeatoLocal_Set($h, "nt", "navigationMode", "deep");
is(ReadingsVal("nt", "navigationMode", ""), "Deep", "the mode is remembered as a reading");

$h->{helper}{queue} = [];
NeatoLocal_Set($h, "nt", "startCleaning");
is($h->{helper}{queue}[0]{cmd}, "SetNavigationMode Deep",
   "a house cleaning re-applies the mode first");
like($h->{helper}{queue}[1]{cmd}, qr/START_HOUSE_CLEANING|Clean House/,
     "and only then starts the run");

# a spot clean is not a house clean
$h->{helper}{queue} = [];
NeatoLocal_Set($h, "nt", "startCleaning", "spot");
unlike($h->{helper}{queue}[0]{cmd}, qr/SetNavigationMode/,
       "a spot clean does not carry the house mode");

like(NeatoLocal_Set($h, "nt", "navigationMode", "bogus"), qr/usage/,
     "an unknown mode is rejected");
is(ReadingsVal("nt", "navigationMode", ""), "Deep", "and does not overwrite the stored one");

$h->{helper}{queue} = [];
delete $h->{helper}{pending};

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

# --- the scan verdict -------------------------------------------------------
# Verbatim shape of what the bridge prints, so a change to the firmware's
# wording shows up here rather than in a user's error message.
my $scan_missing = <<'OUT';
scan: Vodafone-F4D4  -72 dBm  ch 1  enc WPA2
scan: Vodafone Hotspot  -74 dBm  ch 1  enc open
scan: Chefetage  -81 dBm  ch 11  enc WPA2
scan: configured network 'WaxWeazle' is NOT among them -- no password reaches a name that is not on the air on 2.4 GHz
OK scan done
OUT

my $verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_missing);
like($verdict, qr/not on the air/, "a missing name is named as the cause");
unlike($verdict, qr/Check name and password/,
       "and the password is not offered as a possibility any more");
like($verdict, qr/Vodafone-F4D4 \(-72 dBm, ch 1, WPA2\)/,
     "the scan list carries level, channel and encryption");
like($verdict, qr/Vodafone Hotspot \(-74 dBm, ch 1, open\)/,
     "a name with a space survives the parse");

my $scan_present = <<'OUT';
scan: WaxWeazle  -58 dBm  ch 6  enc WPA2
scan: configured network 'WaxWeazle' is there, channel 6, -58 dBm, enc WPA2
OK scan done
OUT

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_present);
like($verdict, qr/password or the encryption/, "a name that is on the air points at the password");
unlike($verdict, qr/not on the air/, "and not at the name");

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", "scan: failed (-2), the radio would not scan\nOK scan done\n");
like($verdict, qr/scan itself did not run/, "a failed scan says nothing about the reception");
unlike($verdict, qr/sees no 2\.4 GHz network/, "and is not reported as an empty room");

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", "scan: nothing in range (2.4 GHz only)\nOK scan done\n");
like($verdict, qr/sees no 2\.4 GHz network/, "an empty room is reported as one");

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", "");
like($verdict, qr/did not answer/, "no answer at all is its own case");

# --- the reason code outranks the scan --------------------------------------
# The board's own disconnect reason comes from the association attempt; the
# scan is circumstantial. A partial scan must not overrule it.
my $status_pw  = "ssid WaxWeazle\npsk 16 characters\nstored 1\nconnected 0\nrssi -100\nmac 84:CC:A8:11:22:33\nreason 15 password refused (4-way handshake timed out)\n";
my $status_gone = "ssid WaxWeazle\npsk set\nstored 1\nconnected 0\nrssi -100\nreason 201 network not found\n";
my $status_none = "ssid WaxWeazle\npsk set\nstored 1\nconnected 0\nrssi -100\nreason 0\n";

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_missing, $status_pw);
like($verdict, qr/refused the password/, "reason 15 names the password");
like($verdict, qr/received a 16 character password/,
     "and reports the length that arrived, so a mangled one can be counted");
like($verdict, qr/MAC 84:CC:A8:11:22:33/, "and the MAC the router would list");
unlike($verdict, qr/not on the air/,
       "even though the scan missed the network, the reason code wins");

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_missing, $status_gone);
like($verdict, qr/did not find 'WaxWeazle'/, "reason 201 names a missing network");

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_missing, "ssid x\nreason 203 association refused\n");
like($verdict, qr/reason 203: association refused/, "another code is named, not guessed at");
like($verdict, qr/before the password is ever checked/,
     "and placed before the password check, where reason 202 happens");

# Reason 2 is "previous authentication no longer valid" -- ambiguous, and the
# one that sent this search after a password that was already correct.
$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_missing,
                                  "ssid x\npsk 16 characters\nmac 84:CC:A8:11:22:33\nreason 2\n");
like($verdict, qr/not proof of a wrong password/, "reason 2 does not accuse the password");
like($verdict, qr/MAC filter/, "and names what else produces it");
unlike($verdict, qr/refused the password/, "it is not reported as a refusal either");

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_missing, "ssid x\nreason 77\n");
like($verdict, qr/reason 77: unknown/, "an unknown code keeps its number");

# The case from the field: the network is plainly there, strong, and refuses
# during authentication -- with WPA3 in the mix.
my $scan_wpa3 = <<'OUT';
scan: WaxWeazle  -38 dBm  ch 6  enc WPA2/WPA3
scan: Chefetage  -75 dBm  ch 1  enc WPA2
scan: configured network 'WaxWeazle' is there, channel 6, -38 dBm, enc WPA2/WPA3
OK scan done
OUT

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_wpa3,
                                  "ssid WaxWeazle\npsk 16 characters\nmac 44:B1:76:19:7A:CC\nreason 202\n");
like($verdict, qr/WPA3 handshake is the first thing to rule out/,
     "WPA3 on the refusing network is named");
like($verdict, qr/WaxWeazle \(-38 dBm, ch 6, WPA2\/WPA3\)/,
     "and the reading it rests on is shown");

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_present,
                                  "ssid WaxWeazle\nreason 202\n");
unlike($verdict, qr/WPA3/, "a WPA2 network is not accused of a WPA3 problem");

$verdict = NeatoLocal_ScanVerdict("WaxWeazle", $scan_missing, $status_none);
like($verdict, qr/not on the air/, "with no reason recorded the scan decides again");

# --- credentials handed over at flash time ----------------------------------
# The block the firmware reads on its first boot. Its layout is a contract with
# the firmware's SEED_* defines, so it is pinned down here byte for byte.
my $blob = NeatoLocal_SeedBlob("WaxWeazle", "sixteencharacter");
is(length($blob), 128, "the credentials block is one flash write");
is(substr($blob, 0, 10), "NEATOSEED1", "it is recognisable");
is(ord(substr($blob, 10, 1)), 9, "the name length is stated");
is(ord(substr($blob, 11, 1)), 16, "the password length too");
is(substr($blob, 12, 9), "WaxWeazle", "the name sits at a fixed offset");
is(substr($blob, 12 + 32, 16), "sixteencharacter", "and so does the password");
is(substr($blob, 108), "\xFF" x 20, "the rest is what erased flash holds");

# A name with a space is exactly why the arguments are quoted, so it has to
# survive into the block.
$blob = NeatoLocal_SeedBlob("My WLAN", "pass phrase");
is(substr($blob, 12, 7), "My WLAN", "a name with a space survives");
is(substr($blob, 12 + 32, 11), "pass phrase", "a password with a space too");

is(NeatoLocal_SeedBlob("", "x"), undef, "an empty name is refused");
is(NeatoLocal_SeedBlob("x" x 33, "y"), undef, "an over-long name is refused");
is(NeatoLocal_SeedBlob("x", "y" x 65), undef, "an over-long password is refused");
isnt(NeatoLocal_SeedBlob("x", ""), undef, "an open network needs no password");

# The offset is read from the metadata CI writes beside the image.
my $meta = "neato_bridge 0.13.0\nboard:  ESP32-C3\nseed offset: 0x3d0000\n";
is(NeatoLocal_SeedOffset($meta), "0x3d0000", "the offset comes from the metadata");
is(NeatoLocal_SeedOffset("neato_bridge 0.9.0\n"), undef,
   "an image without it is recognised as such");
is(NeatoLocal_SeedOffset(undef), undef, "and a missing file does not crash the run");

# Quoted or not must not change what arrives -- and whatever follows the name
# is the password, spaces and all.
my ($qs, $qp) = NeatoLocal_SplitCredentials('"My WLAN"', '"pass phrase"');
my ($us, $up) = NeatoLocal_SplitCredentials("WaxWeazle", "secret");
is("$qs|$qp", "My WLAN|pass phrase", "quoted values lose their quotes");
is("$us|$up", "WaxWeazle|secret", "unquoted values come through unchanged");
my ($ms, $mp) = NeatoLocal_SplitCredentials("WaxWeazle");
is($ms, "WaxWeazle", "a name without a password is still returned");
is($mp, undef, "and the missing password is distinguishable from an empty one");

# --- a worker's result has to survive the trip back to FHEM -----------------
# Blocking.pm delivers it as one telnet line. A newline in it breaks the command
# in half, the callback never runs, and nothing is logged -- the run vanishes and
# the device keeps saying "running". This is what that failure looked like.
is(NeatoLocal_OneLine("esptool v4.7\nWriting at 0x1000\nHash of data verified"),
   "esptool v4.7 -- Writing at 0x1000 -- Hash of data verified",
   "a multi-line tool output is folded onto one line");
unlike(NeatoLocal_OneLine("a\nb"), qr/\n/, "no newline survives");
unlike(NeatoLocal_OneLine("Writing\rat 50%\rat 100%"), qr/\r/,
       "and no carriage return either, which esptool draws progress with");
is(NeatoLocal_OneLine("done\n\n\n"), "done", "trailing blank lines are dropped");
is(NeatoLocal_OneLine(undef), "", "an undefined result does not crash the callback");

# The separator must not gain fields: the result is split on '|', so a newline
# turning into one would move the address into the output field.
my $folded = NeatoLocal_OneLine("fl|OK|192.168.1.61|Writing\nHash verified");
is(scalar(split(/\|/, $folded)), 4, "folding does not add fields");
my (undef, undef, $foldedIp) = split(/\|/, $folded, 4);
is($foldedIp, "192.168.1.61", "so the address still arrives as the address");

# Neither Done nor Aborted is guaranteed, so the reading must not stay on
# "running" for ever.
{
    my ($wh, $wr) = mkdev("wd NeatoLocal 192.168.1.42:23");
    $wh->{helper}{flashRunning} = time();
    readingsSingleUpdate($wh, "lastFlash", "running", 1);

    NeatoLocal_FlashWatch($wh);
    is($wh->{helper}{flashRunning}, undef, "the watchdog releases the lock");
    like(ReadingsVal("wd", "lastFlash", ""), qr/no answer/,
         "and says the run never reported back");

    # It must not talk over a run that ended properly.
    readingsSingleUpdate($wh, "lastFlash", "ok, bridge at 192.168.1.61", 1);
    NeatoLocal_FlashWatch($wh);
    like(ReadingsVal("wd", "lastFlash", ""), qr/bridge at/,
         "a finished run is left alone");
}

# --- a silent robot is not a missing bridge ---------------------------------
# During setup the bridge is up and the robot is not wired to it yet. Calling
# that "unreachable" sends people looking for a fault in the bridge.
{
    my ($sh, $sr) = mkdev("sil NeatoLocal 192.168.1.150:23");
    $sh->{helper}{failCount} = 8;

    $sh->{FD} = 38;                       # DevIo holds an open connection
    NeatoLocal_UpdateState($sh);
    is(ReadingsVal("sil", "state", ""), "robotSilent",
       "a standing connection with a silent robot is named as such");

    delete $sh->{FD};                     # and drops it when the link goes
    NeatoLocal_UpdateState($sh);
    is(ReadingsVal("sil", "state", ""), "unreachable",
       "a connection that is gone is still unreachable");

    # A robot that answers again clears it either way.
    $sh->{FD} = 38;
    $sh->{helper}{failCount} = 0;
    readingsSingleUpdate($sh, "isDocked", 1, 1);
    NeatoLocal_UpdateState($sh);
    isnt(ReadingsVal("sil", "state", ""), "robotSilent",
         "an answer ends it");
}

is(NeatoLocal_LinkUp({ TRANSPORT => "none" }), 0,
   "a device without an address has no link");
is(NeatoLocal_LinkUp({ TRANSPORT => "http" }), 1,
   "HTTP reports its failures per request, so it counts as up");
is(NeatoLocal_LinkUp({ TRANSPORT => "tcp" }), 0, "no handle, no link");
is(NeatoLocal_LinkUp({ TRANSPORT => "serial", USBDev => 1 }), 1,
   "a serial handle counts too");

# --- clearing what the robot reports ---------------------------------------
# GetErr Clear dismisses errors only; the robot's own help says exactly that.
# An alert survives it, and an alert nobody can dismiss looks like a defect.
{
    my ($ch, $cr) = mkdev("clr NeatoLocal 192.168.1.42:23");
    $ch->{helper}{queue} = [];
    @WRITTEN = ();
    NeatoLocal_Set($ch, "clr", "clearError");

    # The first goes out at once, the rest wait in the queue for its answer.
    my @queued = (@WRITTEN, map { $_->{cmd} } @{$ch->{helper}{queue}});
    @queued = map { my $c = $_; $c =~ s/\s+$//; $c } @queued;

    is(scalar(@queued), 3, "clearError sends three commands");
    is($queued[0], "GetErr Clear", "first the documented one, for errors");
    is($queued[1], "SetUIError clearall", "then the undocumented one, for alerts");
    is($queued[2], "GetErr", "and reads back what is left");
}

# --- a mode that costs the robot its next run ------------------------------
# explore leaves a D6 waiting for map IDs that nothing delivers, and afterwards
# it accepts cleaning commands without acting on them until it is power-cycled.
{
    my ($eh, $er) = mkdev("exp NeatoLocal 192.168.1.42:23");
    $eh->{helper}{skey} = "deadbeef";
    $eh->{helper}{queue} = [];
    @WRITTEN = ();

    my $refusal = NeatoLocal_Set($eh, "exp", "startCleaning", "explore");
    like($refusal, qr/switched off and on again/,
         "explore is refused, with what it costs");
    like($refusal, qr/startCleaning explore force/, "and how to do it anyway");
    is(scalar(@WRITTEN), 0, "and nothing reaches the robot");

    $refusal = NeatoLocal_Set($eh, "exp", "startCleaning", "persistent");
    like($refusal, qr/switched off and on again/, "persistent likewise");

    # house and spot are unaffected -- they are the button path, not the app.
    @WRITTEN = ();
    $eh->{helper}{queue} = [];
    is(NeatoLocal_Set($eh, "exp", "startCleaning", "house"), undef,
       "house still goes through");
    ok(scalar(@WRITTEN) > 0, "and reaches the robot");

    # force is the way past it, for anyone who wants to try. A command may wait
    # in the queue rather than go out at once, so both are counted.
    @WRITTEN = ();
    $eh->{helper}{queue} = [];
    delete $eh->{helper}{pending};
    is(NeatoLocal_Set($eh, "exp", "startCleaning", "explore", "force"), undef,
       "force gets through");
    my @sent = (@WRITTEN, map { $_->{cmd} } @{$eh->{helper}{queue}});
    ok(scalar(grep { /Clean Explore/ } @sent) > 0, "and sends Clean Explore");
}
