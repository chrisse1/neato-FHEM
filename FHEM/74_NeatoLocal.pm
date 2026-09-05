##############################################################################
#
#     74_NeatoLocal.pm
#     Local (cloud-free) control of Neato Botvac robots via their serial
#     console -- either over the robot's USB port, over a TCP serial bridge
#     (ESP8266/ESP32, ser2net) or over an HTTP bridge such as OpenNeato.
#
#     The Neato cloud (nucleo/beehive.neatocloud.com) was shut down in Q4/2025,
#     which rendered the app and every cloud based module (e.g. 74_BOTVAC.pm)
#     useless. The robot firmware itself still does everything locally -- it
#     just lost the component that used to trigger it. This module talks to the
#     robot's built-in serial console instead.
#
#     Readings and set commands intentionally follow 74_BOTVAC.pm where a
#     sensible mapping exists, so existing notify/DOIF definitions keep working.
#
#     This file is part of https://github.com/chrisse1/neato-FHEM
#     Released under the same license as FHEM itself (GPLv2).
#
##############################################################################

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);

my $NeatoLocal_VERSION = "0.1.0";

# The Neato console terminates every response with SUB / Ctrl-Z (0x1A).
my $NeatoLocal_EOR = chr(26);

# Commands that are safe to send while the robot operates normally, i.e. they
# do NOT require "TestMode On". Everything requiring TestMode is left to the
# user via "set raw" -- TestMode disables the robot's buttons and its normal
# cleaning behaviour and must never be entered behind the user's back.
my %NeatoLocal_sets = (
    "startCleaning"  => "house,spot,explore,persistent",
    "stop"           => "noArg",
    "pause"          => "noArg",
    "resume"         => "noArg",
    "sendToBase"     => "noArg",
    "findMe"         => "noArg",
    "clearError"     => "noArg",
    "navigationMode" => "Normal,Gentle,Deep,Quick",
    "syncTime"       => "noArg",
    "button"         => "soft,start,spot,back,up,down,IRstart,IRspot,IRfront,"
                      . "IRback,IRleft,IRright,IRhome,IReco",
    "statusRequest"  => "noArg",
    "reconnect"      => "noArg",
    "testMode"       => "on,off",
    "raw"            => "textField",
);

my %NeatoLocal_gets = (
    "help"      => "textField",
    "raw"       => "textField",
    "version"   => "noArg",
    "charger"   => "noArg",
    "motors"    => "noArg",
    "sensors"   => "noArg",
    "usage"     => "noArg",
    "settings"  => "noArg",
    "wifiStatus"=> "noArg",
);

# set name => attribute holding the serial command, default command.
# The defaults are taken from the console of a BotVac D6 Connected running
# software 4.5.3.189 (see docs/reference-dump-botvac-d6.txt). Any firmware that
# names its commands differently can be adapted through the attributes.
my %NeatoLocal_cmdMap = (
    "startCleaning" => [ "cmdCleanHouse",      "Clean House"          ],
    "spot"          => [ "cmdCleanSpot",       "Clean Spot"           ],
    "explore"       => [ "cmdCleanExplore",    "Clean Explore"        ],
    "persistent"    => [ "cmdCleanPersistent", "Clean Persistent"     ],
    "stop"          => [ "cmdCleanStop",       "Clean Stop"           ],
    # The console offers no pause/resume of its own. Pressing Start while the
    # robot cleans pauses it and pressing it again resumes, so both map to the
    # same simulated button -- it toggles rather than setting a state.
    "pause"         => [ "cmdCleanPause",      "SetButton start"      ],
    "resume"        => [ "cmdCleanResume",     "SetButton start"      ],
    # No documented dock command exists; the home key of the IR remote is the
    # closest equivalent the firmware exposes.
    "sendToBase"    => [ "cmdSendToBase",      "SetButton IRhome"     ],
    "findMe"        => [ "cmdFindMe",          "PlaySound SoundID 20" ],
);

# SetButton accepts these, per the robot's own help output.
my @NeatoLocal_buttons = qw(soft start spot back up down
                            IRstart IRspot IRfront IRback
                            IRleft IRright IRhome IReco);

# SetNavigationMode
my @NeatoLocal_navModes = qw(Normal Gentle Deep Quick);

##############################################################################
# FHEM interface
##############################################################################

sub NeatoLocal_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}      = "NeatoLocal_Define";
    $hash->{UndefFn}    = "NeatoLocal_Undef";
    $hash->{DeleteFn}   = "NeatoLocal_Undef";
    $hash->{ShutdownFn} = "NeatoLocal_Shutdown";
    $hash->{SetFn}      = "NeatoLocal_Set";
    $hash->{GetFn}      = "NeatoLocal_Get";
    $hash->{AttrFn}     = "NeatoLocal_Attr";
    $hash->{ReadFn}     = "NeatoLocal_Read";
    $hash->{ReadyFn}    = "NeatoLocal_Ready";

    $hash->{AttrList} = "disable:0,1 disabledForIntervals "
                      . "interval timeout "
                      . "pollErrors:0,1 pollMotors:0,1 "
                      . "cmdCleanHouse cmdCleanSpot cmdCleanStop "
                      . "cmdCleanExplore cmdCleanPersistent "
                      . "cmdCleanPause cmdCleanResume cmdSendToBase cmdFindMe "
                      . "httpPath httpMethod:POST,GET "
                      . $readingFnAttributes;

    return undef;
}

sub NeatoLocal_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t][ \t]*", $def);

    return "Usage: define <name> NeatoLocal <serialDevice|host:port|http://host[:port]>"
        if (int(@a) != 3);

    my $name = $a[0];
    my $dev  = $a[2];

    $hash->{VERSION}         = $NeatoLocal_VERSION;
    $hash->{helper}{queue}   = [];
    $hash->{helper}{buffer}  = "";
    delete $hash->{helper}{pending};

    if ($dev =~ m/^https?:\/\//i) {
        $dev =~ s/\/+$//;
        $hash->{TRANSPORT} = "http";
        $hash->{URL}       = $dev;
        delete $hash->{DeviceName};
    }
    else {
        # a plain device path without baudrate gets the Neato default
        $dev .= "\@115200" if ($dev =~ m/^\// && $dev !~ m/\@/);
        $hash->{TRANSPORT}  = ($dev =~ m/^\//) ? "serial" : "tcp";
        $hash->{DeviceName} = $dev;
    }

    Log3 $name, 3, "NeatoLocal ($name) - defined, transport "
                 . $hash->{TRANSPORT} . ", device $dev";

    if ($hash->{TRANSPORT} eq "http") {
        readingsSingleUpdate($hash, "state", "initialized", 1);
        NeatoLocal_Init($hash) if ($init_done);
    }
    else {
        DevIo_CloseDev($hash);
        return DevIo_OpenDev($hash, 0, "NeatoLocal_Init", "NeatoLocal_Callback");
    }

    return undef;
}

sub NeatoLocal_Undef($$) {
    my ($hash, $arg) = @_;

    NeatoLocal_LeaveTestMode($hash);
    RemoveInternalTimer($hash);
    DevIo_CloseDev($hash) if ($hash->{TRANSPORT} ne "http");

    return undef;
}

sub NeatoLocal_Shutdown($) {
    my ($hash) = @_;

    NeatoLocal_LeaveTestMode($hash);
    RemoveInternalTimer($hash);
    DevIo_CloseDev($hash) if ($hash->{TRANSPORT} ne "http");

    return undef;
}

sub NeatoLocal_Attr(@) {
    my ($cmd, $name, $attrName, $attrVal) = @_;
    my $hash = $defs{$name};

    if ($attrName eq "interval") {
        if ($cmd eq "set") {
            return "interval must be a number >= 10 (seconds)"
                if (!defined($attrVal) || $attrVal !~ m/^\d+$/ || $attrVal < 10);
        }
        NeatoLocal_RestartTimer($hash, ($cmd eq "set") ? $attrVal : 60);
    }

    if ($attrName eq "timeout" && $cmd eq "set") {
        return "timeout must be a number between 1 and 60 (seconds)"
            if (!defined($attrVal) || $attrVal !~ m/^\d+$/ || $attrVal < 1 || $attrVal > 60);
    }

    if ($attrName eq "disable") {
        if ($cmd eq "set" && defined($attrVal) && $attrVal eq "1") {
            NeatoLocal_LeaveTestMode($hash);
            RemoveInternalTimer($hash);
            $hash->{helper}{queue} = [];
            delete $hash->{helper}{pending};
            DevIo_CloseDev($hash) if ($hash->{TRANSPORT} ne "http");
            readingsSingleUpdate($hash, "state", "disabled", 1);
        }
        else {
            if ($hash->{TRANSPORT} eq "http") {
                NeatoLocal_Init($hash);
            }
            else {
                DevIo_OpenDev($hash, 0, "NeatoLocal_Init", "NeatoLocal_Callback");
            }
        }
    }

    return undef;
}

##############################################################################
# connection handling
##############################################################################

sub NeatoLocal_Init($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return undef if (IsDisabled($name));

    $hash->{helper}{queue}  = [];
    $hash->{helper}{buffer} = "";
    delete $hash->{helper}{pending};

    Log3 $name, 4, "NeatoLocal ($name) - initializing communication";

    NeatoLocal_Enqueue($hash, "GetVersion", \&NeatoLocal_ParseVersion);
    NeatoLocal_StatusRequest($hash);
    NeatoLocal_RestartTimer($hash);

    return undef;
}

sub NeatoLocal_Callback($$) {
    my ($hash, $error) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 3, "NeatoLocal ($name) - connection error: $error"
        if (defined($error) && $error ne "");

    return undef;
}

sub NeatoLocal_Ready($) {
    my ($hash) = @_;

    return undef if ($hash->{TRANSPORT} eq "http");
    return undef if (IsDisabled($hash->{NAME}));

    return DevIo_OpenDev($hash, 1, "NeatoLocal_Init", "NeatoLocal_Callback")
        if ($hash->{STATE} eq "disconnected");

    return undef;
}

sub NeatoLocal_RestartTimer($;$) {
    my ($hash, $interval) = @_;
    return undef if (!defined($hash));

    my $name = $hash->{NAME};
    $interval = AttrVal($name, "interval", 60) if (!defined($interval));

    RemoveInternalTimer($hash, "NeatoLocal_Poll");
    return undef if (IsDisabled($name));

    InternalTimer(gettimeofday() + $interval, "NeatoLocal_Poll", $hash, 0);

    return undef;
}

sub NeatoLocal_Poll($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return NeatoLocal_RestartTimer($hash) if (IsDisabled($name));

    if ($hash->{TRANSPORT} ne "http" && $hash->{STATE} eq "disconnected") {
        NeatoLocal_RestartTimer($hash);
        return undef;
    }

    NeatoLocal_StatusRequest($hash);
    NeatoLocal_RestartTimer($hash);

    return undef;
}

##############################################################################
# command queue
##############################################################################

sub NeatoLocal_Enqueue($$;$$) {
    my ($hash, $cmd, $parser, $cl) = @_;
    my $name = $hash->{NAME};

    return "device is disabled" if (IsDisabled($name));
    return "no command given"   if (!defined($cmd) || $cmd eq "");

    push @{$hash->{helper}{queue}}, {
        cmd    => $cmd,
        parser => $parser,
        cl     => $cl,
        ts     => scalar(gettimeofday()),
    };

    # keep the queue bounded, e.g. while the robot sleeps or is unreachable
    if (int(@{$hash->{helper}{queue}}) > 32) {
        shift @{$hash->{helper}{queue}};
        Log3 $name, 2, "NeatoLocal ($name) - command queue overflow, dropped oldest entry";
    }

    NeatoLocal_SendNext($hash);

    return undef;
}

sub NeatoLocal_SendNext($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return undef if (defined($hash->{helper}{pending}));

    my $entry = shift @{$hash->{helper}{queue}};
    return undef if (!defined($entry));

    my $timeout = AttrVal($name, "timeout", 10);

    if ($hash->{TRANSPORT} eq "http") {
        my $path   = AttrVal($name, "httpPath", "/api/serial");
        my $method = AttrVal($name, "httpMethod", "POST");
        my $url    = $hash->{URL} . $path . "?cmd=" . urlEncode($entry->{cmd});

        $hash->{helper}{pending} = $entry;

        Log3 $name, 5, "NeatoLocal ($name) - HTTP $method $url";

        HttpUtils_NonblockingGet({
            url      => $url,
            method   => $method,
            timeout  => $timeout,
            data     => "",
            hash     => $hash,
            entry    => $entry,
            callback => \&NeatoLocal_HttpDone,
        });

        return undef;
    }

    if ($hash->{STATE} eq "disconnected") {
        Log3 $name, 4, "NeatoLocal ($name) - not connected, dropping '" . $entry->{cmd} . "'";
        asyncOutput($entry->{cl}, "NeatoLocal: not connected") if ($entry->{cl});
        return undef;
    }

    $hash->{helper}{pending} = $entry;
    $hash->{helper}{buffer}  = "";

    Log3 $name, 5, "NeatoLocal ($name) - sending '" . $entry->{cmd} . "'";
    DevIo_SimpleWrite($hash, $entry->{cmd} . "\n", 2);

    InternalTimer(gettimeofday() + $timeout, "NeatoLocal_Timeout", $hash, 0);

    return undef;
}

sub NeatoLocal_Timeout($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $entry = delete $hash->{helper}{pending};
    return undef if (!defined($entry));

    Log3 $name, 2, "NeatoLocal ($name) - timeout waiting for response to '" . $entry->{cmd} . "'";
    readingsSingleUpdate($hash, "lastError", "timeout on '" . $entry->{cmd} . "'", 1);
    asyncOutput($entry->{cl}, "NeatoLocal: timeout waiting for '" . $entry->{cmd} . "'")
        if ($entry->{cl});

    $hash->{helper}{buffer} = "";
    NeatoLocal_SendNext($hash);

    return undef;
}

sub NeatoLocal_Read($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $buf = DevIo_SimpleRead($hash);
    return undef if (!defined($buf));

    $hash->{helper}{buffer} .= $buf;

    while ($hash->{helper}{buffer} =~ s/^(.*?)\x1a//s) {
        NeatoLocal_Dispatch($hash, $1);
    }

    # a response we never get a terminator for must not eat all memory
    if (length($hash->{helper}{buffer}) > 65536) {
        Log3 $name, 2, "NeatoLocal ($name) - receive buffer overflow, discarding";
        $hash->{helper}{buffer} = "";
    }

    return undef;
}

sub NeatoLocal_HttpDone($$$) {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    delete $hash->{helper}{pending};

    if (defined($err) && $err ne "") {
        Log3 $name, 2, "NeatoLocal ($name) - HTTP error: $err";
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "lastError", $err);
        readingsBulkUpdate($hash, "state", "disconnected");
        readingsEndUpdate($hash, 1);
        asyncOutput($param->{entry}{cl}, "NeatoLocal: $err") if ($param->{entry}{cl});
        NeatoLocal_SendNext($hash);
        return undef;
    }

    NeatoLocal_Dispatch($hash, $data, $param->{entry});

    return undef;
}

sub NeatoLocal_Dispatch($$;$) {
    my ($hash, $raw, $entry) = @_;
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash, "NeatoLocal_Timeout");
    $entry = delete $hash->{helper}{pending} if (!defined($entry));

    if (!defined($entry)) {
        # the console emits a banner and error messages on its own
        $raw =~ s/^\s+|\s+$//g;
        Log3 $name, 4, "NeatoLocal ($name) - unsolicited output: $raw" if ($raw ne "");
        return undef;
    }

    my $body = NeatoLocal_StripEcho($entry->{cmd}, $raw);

    Log3 $name, 5, "NeatoLocal ($name) - response to '" . $entry->{cmd} . "': $body";

    $hash->{helper}{lastResponse} = $body;

    if (ref($entry->{parser}) eq "CODE") {
        eval { $entry->{parser}->($hash, $entry, $body); };
        Log3 $name, 2, "NeatoLocal ($name) - parser error: $@" if ($@);
    }

    asyncOutput($entry->{cl}, ($body ne "") ? $body : "(no output)") if ($entry->{cl});

    NeatoLocal_SendNext($hash);

    return undef;
}

##############################################################################
# response parsing
##############################################################################

sub NeatoLocal_StripEcho($$) {
    my ($cmd, $raw) = @_;

    $raw = "" if (!defined($raw));
    $raw =~ s/\x1a//g;
    $raw =~ s/^[\r\n]+//;
    # the console echoes the command it received
    $raw =~ s/^\s*\Q$cmd\E\s*\r?\n//i;
    $raw =~ s/\s+$//;

    return $raw;
}

sub NeatoLocal_ParseCsv($) {
    my ($body) = @_;
    my %values;

    foreach my $line (split(/\r?\n/, $body)) {
        $line =~ s/\s+$//;
        next if ($line eq "");

        my @f = split(/,/, $line);
        next if (int(@f) < 2);

        my $key = $f[0];
        my $val = defined($f[1]) ? $f[1] : "";
        $key =~ s/^\s+|\s+$//g;
        $val =~ s/^\s+|\s+$//g;
        next if ($key eq "");

        $values{$key} = $val;
    }

    return \%values;
}

sub NeatoLocal_ParseVersion($$$) {
    my ($hash, $entry, $body) = @_;

    # GetVersion rows carry a varying number of value columns
    # ("Software,4,5,3,189,0"), so every key keeps its full list of values.
    my %v;
    foreach my $line (split(/\r?\n/, $body)) {
        $line =~ s/\s+$//;
        next if ($line eq "");

        my @f = split(/,/, $line);
        my $key = shift @f;
        next if (!defined($key));
        $key =~ s/^\s+|\s+$//g;
        next if ($key eq "");

        foreach my $val (@f) {
            $val = "" if (!defined($val));
            $val =~ s/^\s+|\s+$//g;
        }
        $v{$key} = [ grep { $_ ne "" } @f ];
    }

    readingsBeginUpdate($hash);

    # "Model,BotVacD6Connected,905-0496" on the D-series, "ModelID" elsewhere
    foreach my $k ("Model", "ModelID") {
        next if (!defined($v{$k}) || !@{$v{$k}});
        readingsBulkUpdateIfChanged($hash, "model", $v{$k}[0]);
        last;
    }

    readingsBulkUpdateIfChanged($hash, "serialNumber", $v{"Serial Number"}[0])
        if (defined($v{"Serial Number"}) && @{$v{"Serial Number"}});

    # the version is spread over the value columns: 4,5,3,189,0 -> 4.5.3.189.0
    foreach my $k ("Software", "MainBoard Software", "Software Version") {
        next if (!defined($v{$k}) || !@{$v{$k}});
        readingsBulkUpdateIfChanged($hash, "firmware", join(".", @{$v{$k}}));
        last;
    }

    readingsBulkUpdateIfChanged($hash, "ldsSoftware", $v{"LDS Software"}[0])
        if (defined($v{"LDS Software"}) && @{$v{"LDS Software"}});
    readingsBulkUpdateIfChanged($hash, "hardware",
        join(".", @{$v{"MainBoard Version"}}))
        if (defined($v{"MainBoard Version"}) && @{$v{"MainBoard Version"}});

    readingsEndUpdate($hash, 1);

    return undef;
}

sub NeatoLocal_ParseCharger($$$) {
    my ($hash, $entry, $body) = @_;
    my $v = NeatoLocal_ParseCsv($body);

    return undef if (!defined($v->{"FuelPercent"}) && !defined($v->{"ExtPwrPresent"}));

    readingsBeginUpdate($hash);

    if (defined($v->{"FuelPercent"}) && $v->{"FuelPercent"} =~ m/^-?\d+$/) {
        readingsBulkUpdateIfChanged($hash, "batteryPercent", $v->{"FuelPercent"});
        # keep the generic battery reading in sync for FHEMWEB/alarms
        readingsBulkUpdateIfChanged($hash, "batteryState",
            ($v->{"FuelPercent"} > 20) ? "ok" : "low");
    }

    foreach my $map ( [ "ChargingActive", "isCharging" ],
                      [ "ExtPwrPresent",  "isDocked"   ],
                      [ "BatteryOverTemp","batteryOverTemp" ] ) {
        my ($src, $dst) = @$map;
        next if (!defined($v->{$src}));
        readingsBulkUpdateIfChanged($hash, $dst, ($v->{$src} ? 1 : 0));
    }

    readingsBulkUpdateIfChanged($hash, "batteryVoltage", $v->{"VBattV"})
        if (defined($v->{"VBattV"}));

    readingsEndUpdate($hash, 1);

    NeatoLocal_UpdateState($hash);

    return undef;
}

sub NeatoLocal_ParseErr($$$) {
    my ($hash, $entry, $body) = @_;

    # The D-series answers in sections, and an alert is not an error -- a full
    # dust bin must not put the device into the error state:
    #
    #   Error
    #   249 -  (UI_ERROR_DUST_BIN_MISSING)
    #   Alert
    #   248 -  (UI_ERROR_DUST_BIN_EMPTIED)
    #   USB state
    #    NOT connected
    #
    # Older firmware prints the bare code line without any section header; that
    # case is treated as an error, which is what it was.
    my %found = (error => [0, "none"], alert => [0, "none"]);
    my $usb    = "";
    my $section = "error";

    foreach my $line (split(/\r?\n/, $body)) {
        $line =~ s/^\s+|\s+$//g;
        next if ($line eq "");

        if ($line =~ m/^error\b/i)     { $section = "error"; next; }
        if ($line =~ m/^alert\b/i)     { $section = "alert"; next; }
        if ($line =~ m/^usb\s+state/i) { $section = "usb";   next; }

        if ($section eq "usb") {
            $usb = ($line =~ m/not\s+connected/i) ? 0 : 1;
            next;
        }

        next if ($line !~ m/^(\d+)\s*-\s*(.*)$/);
        my ($code, $text) = ($1, $2);

        $text =~ s/^\s+|\s+$//g;
        $text =~ s/^\((.*)\)$/$1/;      # (UI_ERROR_DUST_BIN_MISSING)
        $text = "unknown" if ($text eq "");

        # keep the first entry of each section
        $found{$section} = [$code, $text] if ($found{$section}[0] == 0);
    }

    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash, "errorCode", $found{error}[0]);
    readingsBulkUpdateIfChanged($hash, "error",     $found{error}[1]);
    readingsBulkUpdateIfChanged($hash, "alertCode", $found{alert}[0]);
    readingsBulkUpdateIfChanged($hash, "alert",     $found{alert}[1]);
    readingsBulkUpdateIfChanged($hash, "usbConnected", $usb) if ($usb ne "");
    readingsEndUpdate($hash, 1);

    NeatoLocal_UpdateState($hash);

    return undef;
}

sub NeatoLocal_ParseMotors($$$) {
    my ($hash, $entry, $body) = @_;
    my $v = NeatoLocal_ParseCsv($body);

    return undef if (!defined($v->{"Vacuum_RPM"}));

    my $rpm = ($v->{"Vacuum_RPM"} =~ m/^-?\d+$/) ? $v->{"Vacuum_RPM"} : 0;

    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash, "vacuumRPM", $rpm);
    readingsBulkUpdateIfChanged($hash, "isCleaning", ($rpm > 0) ? 1 : 0);
    readingsEndUpdate($hash, 1);

    # the motor reading is authoritative, drop our optimistic assumption
    $hash->{helper}{assumeCleaning} = 0;

    NeatoLocal_UpdateState($hash);

    return undef;
}

sub NeatoLocal_UpdateState($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $errorCode  = ReadingsVal($name, "errorCode", 0);
    my $charging   = ReadingsVal($name, "isCharging", 0);
    my $docked     = ReadingsVal($name, "isDocked", 0);
    my $cleaning   = ReadingsVal($name, "isCleaning", 0);
    my $assume     = $hash->{helper}{assumeCleaning} ? 1 : 0;

    my $state;
    if ($errorCode) {
        $state = "error";
    }
    elsif ($cleaning || $assume) {
        $state = "cleaning";
    }
    elsif ($charging) {
        $state = "charging";
    }
    elsif ($docked) {
        $state = "docked";
    }
    else {
        $state = "idle";
    }

    readingsSingleUpdate($hash, "state", $state, 1)
        if (ReadingsVal($name, "state", "") ne $state);

    return undef;
}

##############################################################################
# set / get
##############################################################################

sub NeatoLocal_StatusRequest($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    NeatoLocal_Enqueue($hash, "GetCharger", \&NeatoLocal_ParseCharger);
    NeatoLocal_Enqueue($hash, "GetErr", \&NeatoLocal_ParseErr)
        if (AttrVal($name, "pollErrors", 1));
    NeatoLocal_Enqueue($hash, "GetMotors", \&NeatoLocal_ParseMotors)
        if (AttrVal($name, "pollMotors", 1));

    return undef;
}

sub NeatoLocal_MappedCmd($$) {
    my ($hash, $key) = @_;
    my $name = $hash->{NAME};

    my $map = $NeatoLocal_cmdMap{$key};
    return (undef, "unknown command '$key'") if (!defined($map));

    my ($attr, $default) = @$map;
    my $cmd = AttrVal($name, $attr, $default);

    return (undef, "no serial command configured for '$key'. The Botvac D-series "
                 . "syntax for this action is not verified -- run 'get $name help Clean' "
                 . "on your robot and set the attribute $attr accordingly "
                 . "(see docs/serial-commands.md)")
        if (!defined($cmd) || $cmd eq "");

    return ($cmd, undef);
}

sub NeatoLocal_Set($@) {
    my ($hash, $name, $cmd, @args) = @_;

    return "no set value specified" if (!defined($cmd));

    if (!defined($NeatoLocal_sets{$cmd})) {
        my $list = join(" ", map { "$_:" . $NeatoLocal_sets{$_} } sort keys %NeatoLocal_sets);
        return "Unknown argument $cmd, choose one of $list";
    }

    return "device is disabled" if (IsDisabled($name) && $cmd ne "reconnect");

    if ($cmd eq "reconnect") {
        RemoveInternalTimer($hash);
        $hash->{helper}{queue} = [];
        delete $hash->{helper}{pending};
        $hash->{helper}{buffer} = "";
        if ($hash->{TRANSPORT} eq "http") {
            NeatoLocal_Init($hash);
        }
        else {
            DevIo_CloseDev($hash);
            DevIo_OpenDev($hash, 0, "NeatoLocal_Init", "NeatoLocal_Callback");
        }
        return undef;
    }

    if ($cmd eq "statusRequest") {
        NeatoLocal_StatusRequest($hash);
        return undef;
    }

    if ($cmd eq "raw") {
        return "usage: set $name raw <console command>" if (!@args);
        return NeatoLocal_Enqueue($hash, join(" ", @args), \&NeatoLocal_ParseGeneric);
    }

    if ($cmd eq "testMode") {
        my $arg = defined($args[0]) ? lc($args[0]) : "";
        return "usage: set $name testMode <on|off>" if ($arg !~ m/^(on|off)$/);
        $hash->{helper}{testMode} = ($arg eq "on") ? 1 : 0;
        readingsSingleUpdate($hash, "testMode", $arg, 1);
        return NeatoLocal_Enqueue($hash, "TestMode " . (($arg eq "on") ? "On" : "Off"));
    }

    if ($cmd eq "startCleaning") {
        my $mode = defined($args[0]) ? lc($args[0]) : "house";
        return "usage: set $name startCleaning [house|spot|explore|persistent]"
            if ($mode !~ m/^(house|spot|explore|persistent)$/);

        my ($serialCmd, $err) = NeatoLocal_MappedCmd($hash,
            ($mode eq "house") ? "startCleaning" : $mode);
        return $err if (defined($err));

        # some firmware refuses to clean while a USB host is attached
        Log3 $name, 3, "NeatoLocal ($name) - cleaning may be refused while a USB "
                     . "host is attached, see docs/hardware.md"
            if ($hash->{TRANSPORT} eq "serial");

        $hash->{helper}{assumeCleaning} = 1;
        NeatoLocal_UpdateState($hash);

        NeatoLocal_Enqueue($hash, $serialCmd, \&NeatoLocal_ParseGeneric);
        NeatoLocal_Enqueue($hash, "GetErr", \&NeatoLocal_ParseErr);
        return undef;
    }

    if ($cmd eq "clearError") {
        NeatoLocal_Enqueue($hash, "GetErr Clear", \&NeatoLocal_ParseGeneric);
        NeatoLocal_Enqueue($hash, "GetErr", \&NeatoLocal_ParseErr);
        return undef;
    }

    if ($cmd eq "navigationMode") {
        my $mode = defined($args[0]) ? ucfirst(lc($args[0])) : "";
        return "usage: set $name navigationMode <"
             . join("|", @NeatoLocal_navModes) . ">"
            if (!grep { $_ eq $mode } @NeatoLocal_navModes);
        return NeatoLocal_Enqueue($hash, "SetNavigationMode $mode",
                                  \&NeatoLocal_ParseGeneric);
    }

    if ($cmd eq "button") {
        my $button = defined($args[0]) ? $args[0] : "";
        return "usage: set $name button <"
             . join("|", @NeatoLocal_buttons) . ">"
            if (!grep { lc($_) eq lc($button) } @NeatoLocal_buttons);
        NeatoLocal_Enqueue($hash, "SetButton $button", \&NeatoLocal_ParseGeneric);
        NeatoLocal_StatusRequest($hash);
        return undef;
    }

    if ($cmd eq "syncTime") {
        # The scheduler clock has no battery-backed source any more now that the
        # cloud and its NTP trigger are gone, so FHEM is the only thing left
        # that knows what time it is.
        my @t = localtime(time());
        my $serialCmd = sprintf("SetTime Day %d Hour %d Min %d Sec %d",
                                $t[6], $t[2], $t[1], $t[0]);
        NeatoLocal_Enqueue($hash, $serialCmd, \&NeatoLocal_ParseGeneric);
        return undef;
    }

    if ($cmd eq "stop" || $cmd eq "pause" || $cmd eq "resume"
        || $cmd eq "sendToBase" || $cmd eq "findMe") {

        my ($serialCmd, $err) = NeatoLocal_MappedCmd($hash, $cmd);
        return $err if (defined($err));

        $hash->{helper}{assumeCleaning} = 0 if ($cmd ne "resume");
        $hash->{helper}{assumeCleaning} = 1 if ($cmd eq "resume");

        NeatoLocal_Enqueue($hash, $serialCmd, \&NeatoLocal_ParseGeneric);
        NeatoLocal_StatusRequest($hash);
        return undef;
    }

    return undef;
}

sub NeatoLocal_ParseGeneric($$$) {
    my ($hash, $entry, $body) = @_;

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "lastCommand", $entry->{cmd});
    readingsBulkUpdate($hash, "lastResponse", substr($body, 0, 255));
    readingsEndUpdate($hash, 1);

    return undef;
}

sub NeatoLocal_Get($@) {
    my ($hash, $name, $cmd, @args) = @_;

    return "no get value specified" if (!defined($cmd));

    if (!defined($NeatoLocal_gets{$cmd})) {
        my $list = join(" ", map { "$_:" . $NeatoLocal_gets{$_} } sort keys %NeatoLocal_gets);
        return "Unknown argument $cmd, choose one of $list";
    }

    return "device is disabled" if (IsDisabled($name));

    my $cl = $hash->{CL};

    if ($cmd eq "help") {
        my $arg = join(" ", @args);
        NeatoLocal_Enqueue($hash, ($arg ne "") ? "Help $arg" : "Help", undef, $cl);
        return undef;
    }

    if ($cmd eq "raw") {
        return "usage: get $name raw <console command>" if (!@args);
        NeatoLocal_Enqueue($hash, join(" ", @args), undef, $cl);
        return undef;
    }

    my %map = (
        "version"    => [ "GetVersion",       \&NeatoLocal_ParseVersion ],
        "charger"    => [ "GetCharger",       \&NeatoLocal_ParseCharger ],
        "motors"     => [ "GetMotors",        \&NeatoLocal_ParseMotors  ],
        "sensors"    => [ "GetAnalogSensors", undef                     ],
        "usage"      => [ "GetUsage",         undef                     ],
        "settings"   => [ "GetUserSettings",  undef                     ],
        "wifiStatus" => [ "GetWifiStatus",    undef                     ],
    );

    my $e = $map{$cmd};
    NeatoLocal_Enqueue($hash, $e->[0], $e->[1], $cl);

    return undef;
}

sub NeatoLocal_LeaveTestMode($) {
    my ($hash) = @_;

    return undef if (!$hash->{helper}{testMode});
    return undef if ($hash->{TRANSPORT} ne "http" && $hash->{STATE} eq "disconnected");

    # never leave the robot deaf to its own buttons. This runs on shutdown and
    # delete, so it has to complete synchronously -- the queue is gone by then.
    if ($hash->{TRANSPORT} eq "http") {
        my $url = $hash->{URL} . AttrVal($hash->{NAME}, "httpPath", "/api/serial")
                . "?cmd=" . urlEncode("TestMode Off");
        HttpUtils_BlockingGet({
            url     => $url,
            method  => AttrVal($hash->{NAME}, "httpMethod", "POST"),
            timeout => 5,
            data    => "",
        });
    }
    else {
        DevIo_SimpleWrite($hash, "TestMode Off\n", 2);
    }
    $hash->{helper}{testMode} = 0;

    return undef;
}

1;

=pod
=item device
=item summary    controls a Neato Botvac locally via its serial console
=item summary_DE steuert einen Neato Botvac lokal ueber die serielle Konsole

=begin html

<a name="NeatoLocal"></a>
<h3>NeatoLocal</h3>
<ul>
  Controls Neato Botvac robots (Botvac Connected, D3 - D7 and the older
  XV / Botvac 6x-8x series) locally, without any cloud service. The Neato
  cloud was shut down in Q4/2025; the robot firmware still performs
  navigation, cleaning and docking on its own, it only lost the component
  that used to trigger it. This module talks to the robot's built-in serial
  console instead.<br><br>

  <b>Note:</b> Botvac D8/D9/D10 use a different mainboard with a
  password protected serial port and are <i>not</i> supported.<br><br>

  Three transports are supported:
  <ul>
    <li><b>serial</b> - the robot's USB port, seen as /dev/ttyACM0 on the
        FHEM host. Good for testing. Be aware that the robot refuses to
        clean while a USB host is attached (error 220).</li>
    <li><b>tcp</b> - a serial-to-network bridge (ser2net, ESP8266/ESP32
        firmware such as botvac-wifi) reachable as host:port.</li>
    <li><b>http</b> - an HTTP bridge such as OpenNeato, which exposes the
        console at /api/serial?cmd=...</li>
  </ul><br>

  <a name="NeatoLocaldefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; NeatoLocal &lt;serialDevice|host:port|http://host&gt;</code><br><br>
    Examples:<br>
    <ul>
      <code>define Staubsauger NeatoLocal /dev/ttyACM0@115200</code><br>
      <code>define Staubsauger NeatoLocal 192.168.1.42:23</code><br>
      <code>define Staubsauger NeatoLocal http://neato.local</code><br>
    </ul>
  </ul><br>

  <a name="NeatoLocalset"></a>
  <b>Set</b>
  <ul>
    <li><b>startCleaning [house|spot|explore|persistent]</b> - starts a cleaning
        run, an exploration run or a run on the stored map</li>
    <li><b>stop</b> - stops the current run</li>
    <li><b>pause</b> / <b>resume</b> - simulates a press of the Start button,
        which pauses a running cleaning and resumes a paused one. The robot
        offers no separate commands, so both send the same toggle.</li>
    <li><b>sendToBase</b> - sends the robot home via the home key of the IR
        remote. If your model ignores it, try
        <code>attr &lt;dev&gt; cmdSendToBase SetButton back</code>.</li>
    <li><b>findMe</b> - plays the "Find me" sound on the robot</li>
    <li><b>clearError</b> - dismisses the reported error (GetErr Clear)</li>
    <li><b>navigationMode &lt;Normal|Gentle|Deep|Quick&gt;</b> - cleaning mode</li>
    <li><b>syncTime</b> - sets the robot's scheduler clock from FHEM. Without
        the cloud nothing else keeps that clock right.</li>
    <li><b>button &lt;name&gt;</b> - simulates any UI or IR button press</li>
    <li><b>statusRequest</b> - polls charger, error and motor state</li>
    <li><b>testMode &lt;on|off&gt;</b> - enters/leaves the console test mode.
        <b>While test mode is on the robot ignores its own buttons and will
        not clean.</b> The module always sends "TestMode Off" on shutdown,
        delete and disable.</li>
    <li><b>raw &lt;command&gt;</b> - sends an arbitrary console command</li>
    <li><b>reconnect</b> - reopens the connection</li>
  </ul><br>

  <a name="NeatoLocalget"></a>
  <b>Get</b>
  <ul>
    <li><b>help [command]</b> - returns the robot's own command list. Use this
        to verify the console syntax of your firmware.</li>
    <li><b>raw &lt;command&gt;</b> - sends a command and returns its output</li>
    <li><b>version</b>, <b>charger</b>, <b>motors</b>, <b>sensors</b>,
        <b>usage</b>, <b>settings</b>, <b>wifiStatus</b></li>
  </ul><br>

  <a name="NeatoLocalattr"></a>
  <b>Attributes</b>
  <ul>
    <li><b>interval</b> - polling interval in seconds, default 60</li>
    <li><b>timeout</b> - response timeout in seconds, default 10</li>
    <li><b>pollErrors</b> - poll GetErr, default 1</li>
    <li><b>pollMotors</b> - poll GetMotors to detect cleaning, default 1</li>
    <li><b>cmdCleanHouse</b>, <b>cmdCleanSpot</b>, <b>cmdCleanExplore</b>,
        <b>cmdCleanPersistent</b>, <b>cmdCleanStop</b>, <b>cmdCleanPause</b>,
        <b>cmdCleanResume</b>, <b>cmdSendToBase</b>, <b>cmdFindMe</b> - the
        console command sent for the respective set command. The defaults come
        from a BotVac D6 Connected running software 4.5.3.189; firmware that
        names things differently can be adapted here.</li>
    <li><b>httpPath</b> - path of the HTTP bridge, default /api/serial</li>
    <li><b>httpMethod</b> - POST (default) or GET</li>
    <li><b>disable</b> - 1 closes the connection and stops polling</li>
  </ul><br>

  <a name="NeatoLocalreadings"></a>
  <b>Readings</b>
  <ul>
    <li><b>state</b> - cleaning, charging, docked, idle, error or disconnected</li>
    <li><b>batteryPercent</b>, <b>batteryState</b>, <b>batteryVoltage</b></li>
    <li><b>isCharging</b>, <b>isDocked</b>, <b>isCleaning</b>, <b>vacuumRPM</b></li>
    <li><b>error</b>, <b>errorCode</b> - a real error, e.g. 249
        UI_ERROR_DUST_BIN_MISSING</li>
    <li><b>alert</b>, <b>alertCode</b> - an alert such as a full dust bin. An
        alert does not put the device into the error state.</li>
    <li><b>usbConnected</b>, <b>lastError</b></li>
    <li><b>model</b>, <b>serialNumber</b>, <b>firmware</b>, <b>ldsSoftware</b>,
        <b>hardware</b></li>
  </ul>
</ul>

=end html

=begin html_DE

<a name="NeatoLocal"></a>
<h3>NeatoLocal</h3>
<ul>
  Steuert Neato Botvac Saugroboter (Botvac Connected, D3 - D7 sowie die
  aelteren XV / Botvac 6x-8x) lokal und ohne Cloud. Die Neato Cloud wurde im
  4. Quartal 2025 abgeschaltet; die Firmware des Roboters kann Navigation,
  Reinigung und Andocken weiterhin selbst - ihr fehlt nur der Ausloeser, der
  bisher aus der Cloud kam. Dieses Modul spricht stattdessen die eingebaute
  serielle Konsole des Roboters an.<br><br>

  <b>Hinweis:</b> Botvac D8/D9/D10 haben ein anderes Mainboard mit
  passwortgeschuetztem seriellen Port und werden <i>nicht</i>
  unterstuetzt.<br><br>

  Drei Anbindungen sind moeglich:
  <ul>
    <li><b>seriell</b> - der USB-Port des Roboters, am FHEM-Rechner z.B. als
        /dev/ttyACM0. Gut zum Testen. Achtung: solange ein USB-Host
        angesteckt ist, verweigert der Roboter die Reinigung (Fehler 220).</li>
    <li><b>tcp</b> - eine seriell-zu-Netzwerk-Bruecke (ser2net, ESP8266/ESP32
        Firmware wie botvac-wifi), erreichbar als host:port.</li>
    <li><b>http</b> - eine HTTP-Bruecke wie OpenNeato, die die Konsole unter
        /api/serial?cmd=... bereitstellt.</li>
  </ul><br>

  <a name="NeatoLocaldefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; NeatoLocal &lt;serielles Geraet|host:port|http://host&gt;</code><br><br>
    Beispiele:<br>
    <ul>
      <code>define Staubsauger NeatoLocal /dev/ttyACM0@115200</code><br>
      <code>define Staubsauger NeatoLocal 192.168.1.42:23</code><br>
      <code>define Staubsauger NeatoLocal http://neato.local</code><br>
    </ul>
  </ul><br>

  <a name="NeatoLocalset"></a>
  <b>Set</b>
  <ul>
    <li><b>startCleaning [house|spot|explore|persistent]</b> - startet eine
        Reinigung, eine Erkundungsfahrt oder eine Fahrt auf der gespeicherten
        Karte</li>
    <li><b>stop</b> - beendet die laufende Reinigung</li>
    <li><b>pause</b> / <b>resume</b> - simuliert einen Druck auf die
        Start-Taste: der pausiert eine laufende Reinigung und setzt eine
        pausierte fort. Der Roboter kennt dafuer keine getrennten Kommandos,
        beide senden denselben Umschalter.</li>
    <li><b>sendToBase</b> - schickt den Roboter ueber die Home-Taste der
        IR-Fernbedienung zurueck. Reagiert dein Modell nicht, hilft
        <code>attr &lt;dev&gt; cmdSendToBase SetButton back</code>.</li>
    <li><b>findMe</b> - spielt den Ton "Find me" ab</li>
    <li><b>clearError</b> - quittiert den gemeldeten Fehler (GetErr Clear)</li>
    <li><b>navigationMode &lt;Normal|Gentle|Deep|Quick&gt;</b> - Reinigungsmodus</li>
    <li><b>syncTime</b> - stellt die Uhr des Zeitgebers aus FHEM. Ohne Cloud
        haelt sonst nichts mehr diese Uhr richtig.</li>
    <li><b>button &lt;name&gt;</b> - simuliert einen beliebigen Tastendruck</li>
    <li><b>statusRequest</b> - fragt Ladezustand, Fehler und Motoren ab</li>
    <li><b>testMode &lt;on|off&gt;</b> - schaltet den Testmodus der Konsole.
        <b>Im Testmodus reagiert der Roboter nicht mehr auf seine Tasten und
        reinigt nicht.</b> Das Modul sendet bei Shutdown, Loeschen und
        Deaktivieren immer "TestMode Off".</li>
    <li><b>raw &lt;Kommando&gt;</b> - sendet ein beliebiges Konsolenkommando</li>
    <li><b>reconnect</b> - baut die Verbindung neu auf</li>
  </ul><br>

  <a name="NeatoLocalget"></a>
  <b>Get</b>
  <ul>
    <li><b>help [Kommando]</b> - liefert die Kommandoliste des Roboters. Damit
        laesst sich die Syntax der eigenen Firmware pruefen.</li>
    <li><b>raw &lt;Kommando&gt;</b> - sendet ein Kommando und gibt die Ausgabe zurueck</li>
    <li><b>version</b>, <b>charger</b>, <b>motors</b>, <b>sensors</b>,
        <b>usage</b>, <b>settings</b>, <b>wifiStatus</b></li>
  </ul><br>

  <a name="NeatoLocalattr"></a>
  <b>Attribute</b>
  <ul>
    <li><b>interval</b> - Abfrageintervall in Sekunden, Standard 60</li>
    <li><b>timeout</b> - Antwort-Timeout in Sekunden, Standard 10</li>
    <li><b>pollErrors</b> - GetErr mit abfragen, Standard 1</li>
    <li><b>pollMotors</b> - GetMotors abfragen, um die Reinigung zu erkennen,
        Standard 1</li>
    <li><b>cmdCleanHouse</b>, <b>cmdCleanSpot</b>, <b>cmdCleanExplore</b>,
        <b>cmdCleanPersistent</b>, <b>cmdCleanStop</b>, <b>cmdCleanPause</b>,
        <b>cmdCleanResume</b>, <b>cmdSendToBase</b>, <b>cmdFindMe</b> - das
        Konsolenkommando fuer das jeweilige set-Kommando. Die Vorgaben stammen
        von einem BotVac D6 Connected mit Software 4.5.3.189; abweichende
        Firmware laesst sich hier anpassen.</li>
    <li><b>httpPath</b> - Pfad der HTTP-Bruecke, Standard /api/serial</li>
    <li><b>httpMethod</b> - POST (Standard) oder GET</li>
    <li><b>disable</b> - 1 schliesst die Verbindung und stoppt die Abfrage</li>
  </ul><br>

  <a name="NeatoLocalreadings"></a>
  <b>Readings</b>
  <ul>
    <li><b>state</b> - cleaning, charging, docked, idle, error oder disconnected</li>
    <li><b>batteryPercent</b>, <b>batteryState</b>, <b>batteryVoltage</b></li>
    <li><b>isCharging</b>, <b>isDocked</b>, <b>isCleaning</b>, <b>vacuumRPM</b></li>
    <li><b>error</b>, <b>errorCode</b> - a real error, e.g. 249
        UI_ERROR_DUST_BIN_MISSING</li>
    <li><b>alert</b>, <b>alertCode</b> - an alert such as a full dust bin. An
        alert does not put the device into the error state.</li>
    <li><b>usbConnected</b>, <b>lastError</b></li>
    <li><b>model</b>, <b>serialNumber</b>, <b>firmware</b>, <b>ldsSoftware</b>,
        <b>hardware</b></li>
  </ul>
</ul>

=end html_DE

=cut
