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
#     The SetEvent command, its UIMGR_EVENT_SMARTAPP_* events, the SKey
#     derivation and the GetState command are not listed in the robot's own
#     Help output. They were reverse engineered by the OpenNeato project
#     (https://github.com/renjfk/OpenNeato, MIT, (c) 2026 Soner Koeksal);
#     the implementation here is an independent reimplementation in Perl,
#     verified against OpenNeato's C++ original on known values.
#
#     This file is part of https://github.com/chrisse1/neato-FHEM
#     Released under the GNU General Public License version 2, the same license
#     as FHEM itself. The full text is in the LICENSE file at the repository
#     root; there is no warranty, to the extent permitted by law.
#
##############################################################################

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use IO::Socket::INET;
use IO::Select;
use Digest::MD5;
use File::Path qw(make_path);

my $NeatoLocal_VERSION = "0.22.0";

# How long a flash or provisioning run may hold the device before the lock is
# treated as left behind. Comfortably above the BlockingCall timeouts, so a run
# that is merely slow is never cut short by it.
my $NeatoLocal_flashLock = 600;

# How long the plan may be computed before the lock counts as left behind, and
# how long BlockingCall lets the worker live. Minutes, not seconds: the search
# tries every rotation over the whole frame for every recording, and eight
# recordings on a small board are a quarter of an hour. It runs niced, in a
# forked process, and nothing waits for it.
my $NeatoLocal_planTimeout = 1800;
my $NeatoLocal_planLock    = 2000;

# Where the images come from when nothing else is configured. The project's CI
# builds both on every firmware change, and the text file beside them carries
# the offset of the partition the credentials block goes to.
#
# Two files, because they go to different places: the first carries bootloader
# and partition table and is written to offset 0 over USB, the second is the
# application alone and is what an update over the air replaces.
my $NeatoLocal_repoRaw =
    "https://raw.githubusercontent.com/chrisse1/neato-FHEM/main/firmware/prebuilt";
my $NeatoLocal_imageURL = "$NeatoLocal_repoRaw/neato_bridge-esp32c3.bin";
my $NeatoLocal_appURL   = "$NeatoLocal_repoRaw/neato_bridge-esp32c3-app.bin";

# The OTA port the bridge listens on; the Arduino default for the ESP32.
my $NeatoLocal_otaPort = 3232;

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
    "ecoMode"        => "on,off",
    "intenseClean"   => "on,off",
    "binFullDetect"  => "on,off",
    "syncTime"       => "noArg",
    "button"         => "soft,start,spot,back,up,down,IRstart,IRspot,IRfront,"
                      . "IRback,IRleft,IRright,IRhome,IReco",
    "flashESP"       => "textField",
    "wifiESP"        => "textField",
    "otaESP"         => "textField",
    "buildPlan"      => "noArg",
    "statusRequest"  => "noArg",
    "reconnect"      => "noArg",
    "testMode"       => "on,off",
    "raw"            => "textField",
);

my %NeatoLocal_gets = (
    "help"      => "textField",
    "serialPorts" => "noArg",
    "raw"       => "textField",
    "version"   => "noArg",
    "charger"   => "noArg",
    "motors"    => "noArg",
    "sensors"   => "noArg",
    "accel"     => "noArg",
    "state"     => "noArg",
    "usage"     => "noArg",
    "warranty"  => "noArg",
    "battery"   => "noArg",
    "settings"  => "noArg",
    "wifiStatus"=> "noArg",
);

# The cloud used an authenticated event API that the Help output does not
# mention. Where an event exists it is the better choice: it drives the robot's
# own UI state machine and keeps map and localization across a pause, which the
# simulated button presses below do not.
my %NeatoLocal_events = (
    "startCleaning" => "UIMGR_EVENT_SMARTAPP_START_HOUSE_CLEANING",
    "spot"          => "UIMGR_EVENT_SMARTAPP_START_SPOT_CLEANING",
    "pause"         => "UIMGR_EVENT_SMARTAPP_PAUSE_CLEANING",
    "resume"        => "UIMGR_EVENT_SMARTAPP_RESUME_CLEANING",
    "stop"          => "UIMGR_EVENT_SMARTAPP_STOP_CLEANING",
    "sendToBase"    => "UIMGR_EVENT_SMARTAPP_SEND_TO_BASE",
);

# set name => [ attribute, fallback command ]. The fallback is used when the
# robot offers no SKey (older firmware) or when useSetEvent is turned off.
# Verified on a BotVac D6 Connected running software 4.5.3.189, see
# docs/reference-dump-botvac-d6.txt.
my %NeatoLocal_cmdMap = (
    "startCleaning" => [ "cmdCleanHouse",      "Clean House"          ],
    "spot"          => [ "cmdCleanSpot",       "Clean Spot"           ],
    "explore"       => [ "cmdCleanExplore",    "Clean Explore"        ],
    "persistent"    => [ "cmdCleanPersistent", "Clean Persistent"     ],
    "stop"          => [ "cmdCleanStop",       "Clean Stop"           ],
    # Pressing Start toggles between pausing and resuming; there are no
    # separate console commands for it.
    "pause"         => [ "cmdCleanPause",      "SetButton start"      ],
    "resume"        => [ "cmdCleanResume",     "SetButton start"      ],
    # Without the event API there is no way to send the robot home: neither
    # SetButton IRhome nor SetButton back does anything on a D6.
    "sendToBase"    => [ "cmdSendToBase",      ""                     ],
    "findMe"        => [ "cmdFindMe",          "PlaySound SoundID 20" ],
);

# SetButton accepts these, per the robot's own help output.
my @NeatoLocal_buttons = qw(soft start spot back up down
                            IRstart IRspot IRfront IRback
                            IRleft IRright IRhome IReco);

# SetNavigationMode
my @NeatoLocal_navModes = qw(Normal Gentle Deep Quick);

# GetUserSettings answers "Key, Value" per line, with the keys spelled out.
# Taken verbatim from a BotVac D6 Connected, see
# docs/reference-dump-botvac-d6.txt.
my %NeatoLocal_settingMap = (
    "Language"                                   => "language",
    "ClickSounds"                                => "clickSounds",
    "LED"                                        => "led",
    "Wall Enable"                                => "wallFollower",
    "Eco Mode"                                   => "ecoMode",
    "IntenseClean"                               => "intenseClean",
    "WiFi"                                       => "wifiEnabled",
    "Melody Sounds"                              => "melodySounds",
    "Warning Sounds"                             => "warningSounds",
    "Bin Full Detect"                            => "binFullDetect",
    "Filter Change Time (seconds)"               => "filterChangeTime",
    "Brush Change Time (seconds)"                => "brushChangeTime",
    "Dirt Bin Alert Reminder Interval (minutes)" => "dirtBinInterval",
);

# set name => the argument SetUserSettings expects
my %NeatoLocal_settingCmds = (
    "ecoMode"      => "EcoMode",
    "intenseClean" => "IntenseClean",
    "binFullDetect"=> "BinFullDetect",
);

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
                      . "interval timeout connectTimeout espPort espImage "
                      . "espAppImage trackRuns:0,1 trackDir trackInterval "
                      . "trackKeepDays mapInterval mapMaxRange "
                      . "trackPose:Smooth,Raw "
                      . "planAuto:0,1 planSources planCell "
                      . "pollErrors:0,1 pollMotors:0,1 pollState:0,1 pollSettings:0,1 useSetEvent:0,1 "
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

    return "Usage: define <name> NeatoLocal [serialDevice|host:port|http://host[:port]]\n"
         . "Leave the address out to define the device before the bridge exists; "
         . "set flashESP and set wifiESP then fill it in."
        if (int(@a) < 2 || int(@a) > 3);

    my $name = $a[0];
    # No address yet: this is the state a device is in between being defined and
    # its bridge being flashed. Everything that talks to the robot is off, but
    # flashESP and wifiESP work -- and wifiESP fills the address in.
    my $dev  = (int(@a) == 3) ? $a[2] : "none";

    $hash->{VERSION}         = $NeatoLocal_VERSION;
    $hash->{helper}{queue}   = [];
    $hash->{helper}{buffer}  = "";
    delete $hash->{helper}{pending};

    if (lc($dev) eq "none") {
        $hash->{TRANSPORT} = "none";
        delete $hash->{DeviceName};
        delete $hash->{URL};

        Log3 $name, 3, "NeatoLocal ($name) - defined without an address, waiting "
                     . "for the bridge";
        readingsSingleUpdate($hash, "state", "unconfigured", 1);
        return undef;
    }

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

        # DevIo opens a TCP connection synchronously, so an unreachable bridge
        # stalls all of FHEM until the connect times out. The bridge is powered
        # from the robot, so it disappears whenever the robot does -- with
        # DevIo's default of 3 seconds that is a visible hiccup every time FHEM
        # retries.
        $hash->{TIMEOUT} = AttrVal($name, "connectTimeout", 2);
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
    DevIo_CloseDev($hash)
        if ($hash->{TRANSPORT} ne "http" && $hash->{TRANSPORT} ne "none");

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

    if ($attrName eq "connectTimeout") {
        if ($cmd eq "set") {
            return "connectTimeout must be a number between 1 and 10 (seconds)"
                if (!defined($attrVal) || $attrVal !~ m/^\d+$/
                    || $attrVal < 1 || $attrVal > 10);
            $hash->{TIMEOUT} = $attrVal;
        }
        else {
            $hash->{TIMEOUT} = 2;
        }
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
    return undef if ($hash->{TRANSPORT} eq "none");

    $hash->{helper}{queue}  = [];
    $hash->{helper}{buffer} = "";
    delete $hash->{helper}{pending};

    $hash->{VERSION} = $NeatoLocal_VERSION;

    Log3 $name, 4, "NeatoLocal ($name) - initializing communication";

    NeatoLocal_Enqueue($hash, "GetVersion", \&NeatoLocal_ParseVersion);
    NeatoLocal_Enqueue($hash, "GetUserSettings", \&NeatoLocal_ParseUserSettings);
    NeatoLocal_Enqueue($hash, "GetWarranty", \&NeatoLocal_ParseWarranty);
    # info carries the design capacity, data the current one; health needs both
    NeatoLocal_Enqueue($hash, "GetCharger info", \&NeatoLocal_ParseBattery);
    NeatoLocal_Enqueue($hash, "GetCharger data", \&NeatoLocal_ParseBattery);
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

    return undef if ($hash->{TRANSPORT} eq "http" || $hash->{TRANSPORT} eq "none");
    return undef if (IsDisabled($hash->{NAME}));

    return DevIo_OpenDev($hash, 1, "NeatoLocal_Init", "NeatoLocal_Callback")
        if ($hash->{STATE} eq "disconnected");

    return undef;
}

sub NeatoLocal_RestartTimer($;$) {
    my ($hash, $interval) = @_;
    return undef if (!defined($hash));

    my $name = $hash->{NAME};
    $interval = NeatoLocal_PollInterval($hash) if (!defined($interval));

    RemoveInternalTimer($hash, "NeatoLocal_Poll");
    return undef if (IsDisabled($name));

    InternalTimer(gettimeofday() + $interval, "NeatoLocal_Poll", $hash, 0);

    return undef;
}

# How long until the next poll. A robot that does not answer -- asleep, not
# wired up yet, or a bridge with nothing behind it -- gets asked less and less
# often instead of filling the log every interval.
sub NeatoLocal_PollInterval($) {
    my ($hash) = @_;
    my $interval = AttrVal($hash->{NAME}, "interval", 60);

    my $fails = $hash->{helper}{failCount};
    $fails = 0 if (!defined($fails));
    return $interval if ($fails < 2);

    my $steps = $fails - 1;
    $steps = 4 if ($steps > 4);          # 2x, 4x, 8x, 16x, then stop growing
    my $backoff = $interval * (2 ** $steps);

    return ($backoff > 3600) ? 3600 : $backoff;
}

sub NeatoLocal_Poll($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # Define runs once, so after "reload" an existing device would keep showing
    # the version it was defined with -- which is exactly the number someone
    # checks to see whether the reload took.
    $hash->{VERSION} = $NeatoLocal_VERSION;

    return NeatoLocal_RestartTimer($hash) if (IsDisabled($name));
    return undef if ($hash->{TRANSPORT} eq "none");

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
    return "no address configured -- flash the bridge first, or give one with "
         . "'modify $name <host:port>'"
        if ($hash->{TRANSPORT} eq "none");
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
        asyncOutput($entry->{cl}, NeatoLocal_WebSafe("NeatoLocal: not connected"))
            if ($entry->{cl});
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

    $hash->{helper}{failCount} = ($hash->{helper}{failCount} || 0) + 1;

    # Say it loudly once, then stop shouting -- a robot that is asleep or not
    # wired up yet would otherwise fill the log forever.
    Log3 $name, ($hash->{helper}{failCount} <= 1) ? 2 : 4,
        "NeatoLocal ($name) - timeout waiting for response to '"
        . $entry->{cmd} . "' (" . $hash->{helper}{failCount} . " in a row)";

    readingsSingleUpdate($hash, "lastError", "timeout on '" . $entry->{cmd} . "'", 1);
    NeatoLocal_UpdateState($hash);
    asyncOutput($entry->{cl},
        NeatoLocal_WebSafe("NeatoLocal: timeout waiting for '" . $entry->{cmd} . "'"))
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
        asyncOutput($param->{entry}{cl}, NeatoLocal_WebSafe("NeatoLocal: $err"))
            if ($param->{entry}{cl});
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

    # the robot is talking to us again
    if ($hash->{helper}{failCount}) {
        Log3 $name, 3, "NeatoLocal ($name) - robot responds again after "
                     . $hash->{helper}{failCount} . " timeouts";
        $hash->{helper}{failCount} = 0;
        NeatoLocal_RestartTimer($hash);
    }

    if (ref($entry->{parser}) eq "CODE") {
        eval { $entry->{parser}->($hash, $entry, $body); };
        Log3 $name, 2, "NeatoLocal ($name) - parser error: $@" if ($@);
    }

    asyncOutput($entry->{cl},
        NeatoLocal_WebSafe(($body ne "") ? $body : "(no output)")) if ($entry->{cl});

    NeatoLocal_SendNext($hash);

    return undef;
}

##############################################################################
# response parsing
##############################################################################

# FHEMWEB pastes an asynchronous answer into a JavaScript call as
# FW_okDialog('...'). A console response contains line breaks and can contain
# quotes and backslashes, each of which breaks that string literal -- the
# browser then reports a syntax error and shows nothing at all.
#
# Everything dangerous is therefore turned into HTML entities rather than
# escaped: entities survive whichever escaping FHEMWEB applies on top, where a
# backslash escape of our own could end up doubled.
sub NeatoLocal_WebSafe($) {
    my ($text) = @_;

    $text = "" if (!defined($text));

    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/'/&#39;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/\\/&#92;/g;
    $text =~ s/\r\n|\r|\n/<br>/g;

    return "<html>" . $text . "</html>";
}

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

# The event API is authenticated with a key derived from the MAC address that
# GetVersion reports in the Serial Number row. RC4 with a fixed seed, the
# keystream XORed over the MAC characters, hex encoded, and a 25th character
# that repeats the seventh -- an oddity of the firmware, not a mistake here.
#
# Algorithm from OpenNeato (MIT, (c) 2026 Soner Koeksal), reimplemented and
# checked against its C++ original.
sub NeatoLocal_ComputeSKey($) {
    my ($serial) = @_;

    return "" if (!defined($serial));
    my $comma = index($serial, ",");
    return "" if ($comma < 0);

    my $mac = substr($serial, $comma + 1, 12);
    return "" if (length($mac) != 12);

    my @seed = (0x68, 0x36, 0x43, 0x58, 0x09, 0x09, 0x3A, 0x3C, 0x2A, 0x7B, 0x59);

    my @s = (0 .. 255);
    my $j = 0;
    foreach my $i (0 .. 255) {
        $j = ($j + $s[$i] + $seed[$i % 11]) & 0xFF;
        @s[$i, $j] = @s[$j, $i];
    }

    my @ks;
    my $ii = 0;
    $j = 0;
    foreach my $k (0 .. 11) {
        $ii = ($ii + 1) & 0xFF;
        $j  = ($j + $s[$ii]) & 0xFF;
        @s[$ii, $j] = @s[$j, $ii];
        $ks[$k] = $s[($s[$ii] + $s[$j]) & 0xFF];
    }

    my $key = "";
    foreach my $k (0 .. 11) {
        $key .= sprintf("%02x", $ks[$k] ^ ord(substr($mac, $k, 1)));
    }

    return $key . substr($key, 6, 1);
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

    # "Serial Number,GPC33719,40bd32d1097a,P" -- the second value column is the
    # MAC the event key is derived from, so the whole row has to be kept, not
    # just the serial itself.
    if (defined($v{"Serial Number"}) && @{$v{"Serial Number"}}) {
        readingsBulkUpdateIfChanged($hash, "serialNumber", $v{"Serial Number"}[0]);

        my $key = NeatoLocal_ComputeSKey(join(",", @{$v{"Serial Number"}}));
        $hash->{helper}{skey} = $key;
        readingsBulkUpdateIfChanged($hash, "commandApi",
            ($key ne "") ? "setEvent" : "legacy");

        Log3 $hash->{NAME}, 3, "NeatoLocal (" . $hash->{NAME} . ") - event API "
            . (($key ne "") ? "available" : "not available, falling back to "
                            . "the documented commands");
    }

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

        # An empty slot is reported as a code, not as an absent line: a D6 with
        # nothing wrong answers "200 -  (UI_ALERT_INVALID)" in both sections.
        # Taking that for a fault would leave the device stuck in state error
        # while the robot happily cleans.
        next if ($code == 200 || $text =~ m/INVALID/i);

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

# GetState is another command the Help output does not mention. It reports what
# the robot itself thinks it is doing, which beats inferring it from the vacuum
# motor's RPM:
#
#   Current UI State is: UIMGR_STATE_STANDBY
#   Current Robot State is: ST_C_Standby
sub NeatoLocal_ParseState($$$) {
    my ($hash, $entry, $body) = @_;

    my ($ui, $robot) = ("", "");
    $ui    = $1 if ($body =~ m/Current UI State is:\s*(\S+)/i);
    $robot = $1 if ($body =~ m/Current Robot State is:\s*(\S+)/i);

    return undef if ($ui eq "" && $robot eq "");

    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash, "uiState", $ui)       if ($ui ne "");
    readingsBulkUpdateIfChanged($hash, "robotState", $robot) if ($robot ne "");
    readingsEndUpdate($hash, 1);

    # a state the robot reports itself is authoritative
    $hash->{helper}{assumeCleaning} = 0;

    NeatoLocal_UpdateState($hash);

    return undef;
}

# Is the robot idle according to its own state machine? Firmware 4.5.3 and
# later report a robot state, which is the reliable one -- the UI state can
# still read STARTHOUSECLEANING while the robot is back in standby.
sub NeatoLocal_StateIsIdle($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $robot = ReadingsVal($name, "robotState", "");
    if ($robot ne "") {
        return ($robot eq "ST_C_Standby" || $robot eq "ST_C_Idle"
                || $robot eq "ST_M2_Charging_StdBy") ? 1 : 0;
    }

    my $ui = ReadingsVal($name, "uiState", "");
    return ($ui eq "UIMGR_STATE_IDLE" || $ui eq "UIMGR_STATE_STANDBY") ? 1 : 0;
}

# GetWarranty carries the two counters that say how hard the robot has been
# used. The values are hex, which the validation code next to them makes plain:
#
#   Item,Value
#   CumulativeCleaningTimeInSecs,00192364
#   CumulativeBatteryCycles,05c2
#   ValidationCode,c2cc3e78
sub NeatoLocal_ParseWarranty($$$) {
    my ($hash, $entry, $body) = @_;
    my $v = NeatoLocal_ParseCsv($body);

    readingsBeginUpdate($hash);

    if (defined($v->{"CumulativeBatteryCycles"})
        && $v->{"CumulativeBatteryCycles"} =~ m/^[0-9a-f]+$/i) {
        readingsBulkUpdateIfChanged($hash, "batteryCycles",
            hex($v->{"CumulativeBatteryCycles"}));
    }

    if (defined($v->{"CumulativeCleaningTimeInSecs"})
        && $v->{"CumulativeCleaningTimeInSecs"} =~ m/^[0-9a-f]+$/i) {
        readingsBulkUpdateIfChanged($hash, "cleaningHours",
            sprintf("%.1f", hex($v->{"CumulativeCleaningTimeInSecs"}) / 3600));
    }

    readingsEndUpdate($hash, 1);

    return undef;
}

# "GetCharger data" asks the smart battery's own gauge rather than the robot.
# Full Charge Capacity against Design Capacity is the state of health, and it
# is the one number that says whether a robot will still make it home.
sub NeatoLocal_ParseBattery($$$) {
    my ($hash, $entry, $body) = @_;
    my $v = NeatoLocal_ParseCsv($body);

    my $design = $v->{"Design Capacity mA"};
    my $full   = $v->{"Full Charge Capacity mA"};

    return undef if (!defined($full));

    readingsBeginUpdate($hash);

    readingsBulkUpdateIfChanged($hash, "batteryCapacityFull", $full);
    readingsBulkUpdateIfChanged($hash, "batteryCapacityDesign", $design)
        if (defined($design));

    # The design capacity only comes with "GetCharger info", so fall back to
    # the value a previous poll stored.
    $design = ReadingsVal($hash->{NAME}, "batteryCapacityDesign", 0)
        if (!defined($design));

    if ($design && $design =~ m/^\d+$/ && $design > 0 && $full =~ m/^\d+$/) {
        readingsBulkUpdateIfChanged($hash, "batteryHealth",
            sprintf("%.0f", $full / $design * 100));
    }

    # the pack counts its own cycles, which beats the robot's tally
    readingsBulkUpdateIfChanged($hash, "batteryCycles", $v->{"Cycle Count"})
        if (defined($v->{"Cycle Count"}) && $v->{"Cycle Count"} =~ m/^\d+$/);

    # despite the label the value is in milli-degrees, as GetAnalogSensors
    # reports the same temperature with an mC unit
    readingsBulkUpdateIfChanged($hash, "batteryTemperature",
        sprintf("%.1f", $v->{"Temperature deciC"} / 1000))
        if (defined($v->{"Temperature deciC"})
            && $v->{"Temperature deciC"} =~ m/^-?\d+$/);

    readingsEndUpdate($hash, 1);

    return undef;
}

sub NeatoLocal_ParseUserSettings($$$) {
    my ($hash, $entry, $body) = @_;

    my $found = 0;
    my $scheduled = 0;

    readingsBeginUpdate($hash);

    foreach my $line (split(/\r?\n/, $body)) {
        $line =~ s/\s+$//;
        next if ($line eq "");

        # "Schedule is Disabled" stands on its own, without a value column
        if ($line =~ m/^Schedule is (\w+)/i) {
            readingsBulkUpdateIfChanged($hash, "scheduleEnabled",
                (lc($1) eq "enabled") ? 1 : 0);
            $found = 1;
            next;
        }

        # the schedule itself follows as one line per day, the empty ones
        # reading "-None-"
        if ($line =~ m/\d\d:\d\d\s+(.+)$/) {
            my $what = $1;
            $what =~ s/\s+$//;
            $scheduled++ if ($what ne "-None-");
            next;
        }

        next if ($line !~ m/^([^,]+),\s*(.*)$/);
        my ($key, $val) = ($1, $2);
        $key =~ s/^\s+|\s+$//g;
        $val =~ s/^\s+|\s+$//g;

        my $reading = $NeatoLocal_settingMap{$key};
        next if (!defined($reading));

        # ON/OFF reads better as on/off next to the set commands
        $val = lc($val) if ($val =~ m/^(ON|OFF)$/i);

        readingsBulkUpdateIfChanged($hash, $reading, $val);
        $found = 1;
    }

    readingsBulkUpdateIfChanged($hash, "scheduledCleanings", $scheduled) if ($found);
    readingsEndUpdate($hash, 1);

    return undef;
}

# Is the transport itself alive? DevIo keeps the handle it opened in one of
# these and drops it again on disconnect.
sub NeatoLocal_LinkUp($) {
    my ($hash) = @_;

    # No handle of its own; HTTP reports its failures per request.
    return 1 if ($hash->{TRANSPORT} eq "http");
    return 0 if ($hash->{TRANSPORT} eq "none");

    return (defined($hash->{FD})
         || defined($hash->{TCPDev})
         || defined($hash->{USBDev})) ? 1 : 0;
}

# ---------------------------------------------------------------- track ----
# What the robot drove, written away while it drives it. The robot keeps no
# record of its own -- OpenNeato solves this the same way, by sampling the pose
# during a run and storing the result. There is no map to fetch; the track is
# the map.
#
# One line per sample, JSON, so anything can read it without a parser for a
# format invented here.

# "Robot Raw pose: X=1.234, Y=-0.567, Theta=90.000, Time=1281.837266"
# The coordinates are metres -- three decimals, and OpenNeato reports the same
# numbers as metres travelled.
sub NeatoLocal_ParsePose($) {
    my ($text) = @_;

    return undef if (!defined($text));
    my ($x, $y, $theta, $time) = ($text =~
        m/X=(-?[\d.]+),\s*Y=(-?[\d.]+),\s*Theta=(-?[\d.]+),\s*Time=(-?[\d.]+)/);

    return undef if (!defined($x));
    return ($x + 0, $y + 0, $theta + 0, $time + 0);
}

# Sessions are files, and files stay until somebody removes them. Deleting is
# the one thing here that cannot be taken back, so it is fenced in: only inside
# the configured directory, only names this module writes itself, only older
# than the cutoff, and never the session currently being recorded.
# One lidar revolution, as GetLDSScan hands it over: 360 rows of angle,
# distance in mm, intensity and an error code in hex, then the rotation speed.
#
# Two filters, and the second one is the one that is easy to miss: every row
# carrying an error code reads 0 mm, so dropping those is obvious -- but in a
# real scan nine rows came back around 16.8 m with error code 0, in runs, where
# nothing returned the beam. The lidar of a Botvac reaches about five metres, so
# anything past that is not a measurement. A filter written against a tidy scan
# would have put those straight into the map.
# Pitch and roll from GetAccel, in degrees, plus the magnitude of what the
# sensor felt.
#
#   Label,Value
#   PitchInDegrees, -2.33
#   RollInDegrees, -1.20
#   XInG, 0.039
#   ...
#   SumInG, 0.951
#
# SumInG travels with them on purpose. An accelerometer measures every
# acceleration, not just gravity, so while the robot pulls away or brakes the
# apparent angle tilts without the robot tilting. A sample whose magnitude is
# not the one the robot shows at rest was taken while it was being pushed
# around, and is worth less than one that matches. Whoever reads the recording
# can tell the two apart only if the number is there.
#
# Note the sensor is NOT calibrated: a D6 standing level on its base reports
# -2.33 / -1.20 degrees at 0.951 g. The numbers are good for a change, not for
# an absolute angle, so anything built on them has to work off the run's own
# resting value rather than off zero.
sub NeatoLocal_ReadAccel($) {
    my ($body) = @_;

    return undef if (!defined($body));

    my ($pitch) = ($body =~ m/PitchInDegrees\s*,\s*(-?[\d.]+)/i);
    my ($roll)  = ($body =~ m/RollInDegrees\s*,\s*(-?[\d.]+)/i);
    my ($sum)   = ($body =~ m/SumInG\s*,\s*(-?[\d.]+)/i);

    return undef if (!defined($pitch) || !defined($roll));

    return ($pitch + 0, $roll + 0, defined($sum) ? $sum + 0 : undef);
}

sub NeatoLocal_ParseAccel($$$) {
    my ($hash, $entry, $body) = @_;
    my $name = $hash->{NAME};

    my ($pitch, $roll, $sum) = NeatoLocal_ReadAccel($body);
    if (!defined($pitch)) {
        Log3 $name, 3, "NeatoLocal ($name) - no angles in the accelerometer answer";
        return undef;
    }

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "pitch", $pitch);
    readingsBulkUpdate($hash, "roll", $roll);
    readingsBulkUpdate($hash, "accelSum", $sum) if (defined($sum));
    readingsEndUpdate($hash, 1);

    return undef;
}

# The same answer during a run, where it is kept for the scan that follows
# rather than written to readings: at mapInterval 5 that would be an event
# every five seconds all run long, and nothing reads it live.
sub NeatoLocal_TrackAccel($$$) {
    my ($hash, $entry, $body) = @_;

    my $track = $hash->{helper}{track};
    return undef if (!$track);

    my ($pitch, $roll, $sum) = NeatoLocal_ReadAccel($body);
    return undef if (!defined($pitch));

    $track->{tilt} = [ $pitch, $roll, $sum ];
    return undef;
}

sub NeatoLocal_ParseLidar($;$) {
    my ($body, $maxRange) = @_;

    return (undef, undef) if (!defined($body));
    $maxRange = 6000 if (!defined($maxRange) || $maxRange !~ m/^\d+$/);

    my @points;
    my $speed;
    my $rows = 0;

    foreach my $line (split(/\r?\n/, $body)) {
        if ($line =~ m/^ROTATION_SPEED,\s*([\d.]+)/) {
            $speed = $1 + 0;
            next;
        }
        next if ($line !~ m/^(\d+),(-?\d+),(-?\d+),([0-9a-fA-F]+)\s*$/);

        my ($angle, $dist, $intensity, $err) = ($1 + 0, $2 + 0, $3 + 0, $4);
        $rows++;

        next if (hex($err) != 0);
        next if ($dist <= 0 || $dist > $maxRange);

        push @points, [$angle, $dist, $intensity];
    }

    return (undef, undef) if (!$rows);
    return (\@points, $speed);
}

sub NeatoLocal_ParseScan($$$) {
    my ($hash, $entry, $body) = @_;
    my $name = $hash->{NAME};

    my $track = $hash->{helper}{track};
    return undef if (!$track);

    my ($points, $speed) =
        NeatoLocal_ParseLidar($body, AttrVal($name, "mapMaxRange", 6000));
    return undef if (!defined($points));

    # A lidar that is not turning measures nothing. It only spins on its own
    # during a run -- switching it on by hand needs TestMode, and in TestMode the
    # robot neither cleans nor obeys its buttons, so that is not done here.
    if (!@$points) {
        Log3 $name, 4, "NeatoLocal ($name) - lidar returned nothing usable"
                     . (defined($speed) ? ", rotation $speed" : "");
        return undef;
    }

    my $fh = $track->{fh};
    my $pts = join(",", map { "[$_->[0],$_->[1]]" } @$points);

    # Taken, not carried over: the field is there when the angle was measured
    # for this scan and absent when it was not. A stale one would be worse than
    # none, because it looks just as trustworthy.
    my $tilt = delete $track->{tilt};
    my $angle = "";
    if ($tilt) {
        $angle = sprintf(",\"tilt\":[%.2f,%.2f%s]", $tilt->[0], $tilt->[1],
                         defined($tilt->[2]) ? sprintf(",%.3f", $tilt->[2]) : "");
    }

    print $fh sprintf("{\"scan\":{\"x\":%.3f,\"y\":%.3f,\"th\":%.1f,"
                    . "\"speed\":%.2f,\"pose\":\"%s\"%s,\"pts\":[%s]}}\n",
                      defined($track->{lastX}) ? $track->{lastX} : 0,
                      defined($track->{lastY}) ? $track->{lastY} : 0,
                      defined($track->{lastTheta}) ? $track->{lastTheta} : 0,
                      defined($speed) ? $speed : 0,
                      AttrVal($name, "trackPose", "Smooth"), $angle, $pts);

    $track->{scans}++;
    return undef;
}

sub NeatoLocal_TrackSweep($;$) {
    my ($hash, $now) = @_;
    my $name = $hash->{NAME};

    my $days = AttrVal($name, "trackKeepDays", 14);
    return 0 if ($days !~ m/^\d+$/ || $days == 0);   # 0 keeps everything

    my $dir = AttrVal($name, "trackDir", "./www/neato");
    return 0 if (!-d $dir);

    $now = time() if (!defined($now));
    my $cutoff = $now - $days * 86400;
    my $open = $hash->{helper}{track} ? $hash->{helper}{track}{file} : "";
    $open = "" if (!defined($open));

    my $dh;
    return 0 if (!opendir($dh, $dir));
    my @entries = readdir($dh);
    closedir($dh);

    my $removed = 0;
    foreach my $entry (@entries) {
        # Exactly what TrackStart writes, nothing else. A directory full of
        # other people's files is not ours to tidy.
        next if ($entry !~ m/^\Q$name\E-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.jsonl$/);

        my $path = "$dir/$entry";
        next if (!-f $path);
        next if ($path eq $open);

        my $age = (stat($path))[9];
        next if (!defined($age) || $age >= $cutoff);

        if (unlink($path)) {
            $removed++;
        }
        else {
            Log3 $name, 2, "NeatoLocal ($name) - cannot remove $path: $!";
        }
    }

    Log3 $name, 3, "NeatoLocal ($name) - removed $removed track file(s) older "
                 . "than $days days"
        if ($removed);

    return $removed;
}

sub NeatoLocal_TrackStart($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return undef if ($hash->{helper}{track});

    my $dir = AttrVal($name, "trackDir", "./www/neato");
    if (!-d $dir) {
        eval { make_path($dir) };
        if (!-d $dir) {
            Log3 $name, 1, "NeatoLocal ($name) - cannot create $dir, not "
                         . "recording the track";
            return undef;
        }
    }

    my @t = localtime();
    my $stamp = sprintf("%04d-%02d-%02d_%02d-%02d-%02d",
                        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    my $file = "$dir/$name-$stamp.jsonl";

    my $fh;
    if (!open($fh, ">", $file)) {
        Log3 $name, 1, "NeatoLocal ($name) - cannot write $file: $!";
        return undef;
    }
    my $old = select($fh); $| = 1; select($old);

    print $fh "{\"device\":\"$name\",\"started\":\"$stamp\","
            . "\"module\":\"$NeatoLocal_VERSION\",\"unit\":\"m\"}\n";

    $hash->{helper}{track} = {
        fh       => $fh,
        file     => $file,
        points   => 0,
        distance => 0,
        rotation => 0,
        since    => time(),
    };

    Log3 $name, 3, "NeatoLocal ($name) - recording the track to $file";
    readingsSingleUpdate($hash, "trackFile", $file, 1);

    NeatoLocal_TrackTimer($hash);
    return undef;
}

sub NeatoLocal_TrackTimer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash, "NeatoLocal_TrackTimer");
    my $track = $hash->{helper}{track};
    return undef if (!$track);

    # The console is single file. A sample that queues behind a status request
    # would only push the queue along without being any fresher for it.
    if (!@{$hash->{helper}{queue}} && !defined($hash->{helper}{pending})) {
        # Smooth, not Raw. Raw is the wheel encoders on their own, and over a
        # run with this much turning it drifts -- which is what makes scans from
        # different moments refuse to line up under any transformation.
        my $which = AttrVal($name, "trackPose", "Smooth");
        $which = "Smooth" if ($which !~ m/^(Smooth|Raw)$/);

        # A scan is 360 rows and takes the console about half a second, so it
        # goes on its own schedule rather than with every pose.
        my $every = AttrVal($name, "mapInterval", 0);
        my $scanDue = ($every =~ m/^\d+$/ && $every > 0
                       && time() - ($track->{lastScan} || 0) >= $every);

        # The angle the robot stands at, ahead of the pose rather than between
        # pose and scan: those two have to stay next to each other, because a
        # scan is only worth anything against the position it was measured
        # from, and every command in between makes that position staler.
        #
        # Why it is recorded at all: a scan taken while the robot sits askew is
        # not noise. The tilted plane cuts the floor along a straight line, so
        # the floor comes back shaped exactly like a wall, at h/sin(angle) --
        # one to two metres at the two or three degrees a robot picks up
        # working its way through a narrow spot. Within one revolution that
        # cannot be told from a real wall, so it is measured rather than
        # reconstructed afterwards.
        if ($scanDue) {
            delete $track->{tilt};
            NeatoLocal_Enqueue($hash, "GetAccel", \&NeatoLocal_TrackAccel);
        }

        NeatoLocal_Enqueue($hash, "GetRobotPos $which", \&NeatoLocal_TrackSample);

        if ($scanDue) {
            $track->{lastScan} = time();
            NeatoLocal_Enqueue($hash, "GetLDSScan", \&NeatoLocal_ParseScan);

            # And the pose again right after it. A revolution takes 0.2 s, but
            # between the two samples around it the robot turns 22 degrees on
            # average -- at three metres that is over a metre of error. Storing
            # both lets whoever draws the map see how stale the scan's pose is,
            # instead of trusting it.
            NeatoLocal_Enqueue($hash, "GetRobotPos $which",
                               \&NeatoLocal_TrackSample);
        }
    }

    my $every = AttrVal($name, "trackInterval", 3);
    $every = 1 if ($every < 1);
    InternalTimer(gettimeofday() + $every, "NeatoLocal_TrackTimer", $hash);

    return undef;
}

sub NeatoLocal_TrackSample($$$) {
    my ($hash, $entry, $body) = @_;
    my $name = $hash->{NAME};

    my $track = $hash->{helper}{track};
    return undef if (!$track);

    my ($x, $y, $theta, $time) = NeatoLocal_ParsePose($body);
    return undef if (!defined($x));

    if (defined($track->{lastX})) {
        my $dx = $x - $track->{lastX};
        my $dy = $y - $track->{lastY};
        $track->{distance} += sqrt($dx * $dx + $dy * $dy);

        # Shortest way round, so a pass through 0/360 does not count as a turn.
        my $dt = $theta - $track->{lastTheta};
        $dt -= 360 while ($dt > 180);
        $dt += 360 while ($dt < -180);
        $track->{rotation} += abs($dt);
    }
    $track->{lastX} = $x;
    $track->{lastY} = $y;
    $track->{lastTheta} = $theta;

    my $fh = $track->{fh};
    print $fh sprintf("{\"t\":%.2f,\"x\":%.3f,\"y\":%.3f,\"th\":%.1f}\n",
                      $time, $x, $y, $theta);
    $track->{points}++;

    return undef;
}

sub NeatoLocal_TrackStop($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash, "NeatoLocal_TrackTimer");
    my $track = delete $hash->{helper}{track};
    return undef if (!$track);

    my $seconds = time() - $track->{since};
    my $fh = $track->{fh};

    print $fh sprintf("{\"summary\":{\"points\":%d,\"scans\":%d,"
                    . "\"distance\":%.1f,\"rotation\":%.0f,\"seconds\":%d}}\n",
                      $track->{points}, $track->{scans} || 0,
                      $track->{distance}, $track->{rotation}, $seconds);
    close($fh);

    Log3 $name, 3, "NeatoLocal ($name) - track finished: $track->{points} "
                 . "points, " . sprintf("%.1f", $track->{distance}) . " m";

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "trackPoints", $track->{points});
    readingsBulkUpdate($hash, "trackDistance", sprintf("%.1f", $track->{distance}));
    readingsBulkUpdate($hash, "trackDuration", $seconds);
    readingsBulkUpdate($hash, "trackScans", $track->{scans} || 0);
    readingsEndUpdate($hash, 1);

    # Right after a run: a new file exists, the robot is on its dock and nothing
    # is waiting on the console.
    NeatoLocal_TrackSweep($hash);

    # The plan is worth recomputing now, for the same reason -- but only if it
    # was asked for. It takes minutes in a forked process, and a recording
    # without scans cannot contribute to it anyway.
    NeatoLocal_PlanStart($hash, 0)
        if (AttrVal($name, "planAuto", 0) && ($track->{scans} || 0) > 0);

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
    my $ui         = ReadingsVal($name, "uiState", "");
    my $robot      = ReadingsVal($name, "robotState", "");
    my $haveState  = ($ui ne "" || $robot ne "") ? 1 : 0;

    my $state;
    # Nothing we think we know is worth anything while the robot is silent.
    if (($hash->{helper}{failCount} || 0) >= 3) {
        # Two different faults that look identical from the outside. A bridge
        # that cannot be reached is a network or power problem; a bridge that
        # answers while the robot does not is usually a cable -- during setup
        # it is simply the normal state, and calling that "unreachable" sends
        # people looking for a fault in the bridge that is not there.
        $state = NeatoLocal_LinkUp($hash) ? "robotSilent" : "unreachable";
    }
    elsif ($errorCode) {
        $state = "error";
    }
    elsif ($ui =~ m/CLEANINGPAUSED/i) {
        $state = "paused";
    }
    # The robot suspends a run on its own when the battery runs low: it heads
    # for the base, charges, and resumes. UIMGR_STATE_CLEANINGSUSPENDED
    # together with ST_M1_Charging_Cleaning is that state, and it is emphatically
    # not cleaning -- a substring match on CLEAN used to call it that.
    elsif ($ui =~ m/SUSPENDED/i) {
        $state = "suspended";
    }
    elsif ($ui =~ m/DOCKING/i) {
        $state = "docking";
    }
    elsif ($haveState && !NeatoLocal_StateIsIdle($hash)
           && $ui =~ m/CLEANING/i && $ui !~ m/PAUSED|SUSPENDED|COMPLETE/i) {
        $state = "cleaning";
    }
    elsif (!$haveState && ($cleaning || $assume)) {
        # no state from the robot, so fall back to the vacuum motor
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

    # Recording follows the run rather than a command: a cleaning started at the
    # robot's own button, or by its schedule, is the one nobody is watching and
    # the one worth having a track of.
    if (AttrVal($name, "trackRuns", 0) && $hash->{TRANSPORT} ne "none") {
        my $running = ($state =~ m/^(cleaning|paused|suspended)$/) ? 1 : 0;

        NeatoLocal_TrackStart($hash) if ($running && !$hash->{helper}{track});
        NeatoLocal_TrackStop($hash)  if (!$running && $hash->{helper}{track});
    }

    return undef;
}

##############################################################################
# set / get
##############################################################################

sub NeatoLocal_StatusRequest($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # A previous set of queries that is still waiting means the robot is slow
    # or silent. Piling more on top would only grow the queue until it
    # overflows, so let the old one finish first.
    if (@{$hash->{helper}{queue}} || defined($hash->{helper}{pending})) {
        Log3 $name, 4, "NeatoLocal ($name) - previous status request still "
                     . "pending, skipping this one";
        return undef;
    }

    NeatoLocal_Enqueue($hash, "GetCharger", \&NeatoLocal_ParseCharger);
    NeatoLocal_Enqueue($hash, "GetState", \&NeatoLocal_ParseState)
        if (AttrVal($name, "pollState", 1));
    NeatoLocal_Enqueue($hash, "GetErr", \&NeatoLocal_ParseErr)
        if (AttrVal($name, "pollErrors", 1));
    # GetState made this redundant, so it is off by default now
    NeatoLocal_Enqueue($hash, "GetMotors", \&NeatoLocal_ParseMotors)
        if (AttrVal($name, "pollMotors", 0));
    # settings change rarely, so they are fetched on connect, not every cycle
    NeatoLocal_Enqueue($hash, "GetUserSettings", \&NeatoLocal_ParseUserSettings)
        if (AttrVal($name, "pollSettings", 0));

    return undef;
}

sub NeatoLocal_MappedCmd($$) {
    my ($hash, $key) = @_;
    my $name = $hash->{NAME};

    my $map = $NeatoLocal_cmdMap{$key};
    return (undef, "unknown command '$key'") if (!defined($map));

    my ($attr, $fallback) = @$map;

    # an explicitly configured attribute always wins
    my $configured = AttrVal($name, $attr, undef);
    return ($configured, undef) if (defined($configured) && $configured ne "");

    # the event API drives the robot's own state machine, so prefer it
    my $skey = $hash->{helper}{skey};
    if (defined($NeatoLocal_events{$key})
        && defined($skey) && $skey ne ""
        && AttrVal($name, "useSetEvent", 1)) {
        return ("SetEvent event " . $NeatoLocal_events{$key} . " SKey " . $skey, undef);
    }

    return (undef, "no command available for '$key' on this robot. It needs the "
                 . "event API, which requires the MAC from GetVersion -- run "
                 . "'get $name version' and check the reading commandApi. A "
                 . "command can also be set by hand via the attribute $attr.")
        if (!defined($fallback) || $fallback eq "");

    return ($fallback, undef);
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

    if ($cmd eq "flashESP" || $cmd eq "wifiESP") {
        # The lock carries the time it was taken. A run that was killed -- by
        # the timeout, by a FHEM restart, by anything -- would otherwise leave
        # the device refusing every further attempt with no way back except
        # restarting FHEM.
        my $since = $hash->{helper}{flashRunning};
        if ($since) {
            my $age = time() - ($since =~ m/^\d+$/ ? $since : 0);
            return "a flash or provisioning run has been going for $age s. "
                 . "It is given up on after $NeatoLocal_flashLock s."
                if ($age < $NeatoLocal_flashLock);

            Log3 $name, 2, "NeatoLocal ($name) - the previous run left its lock "
                         . "behind $age s ago; starting anyway";
        }

        my $port = NeatoLocal_EspPort($name);

        if ($cmd eq "flashESP") {
            # The bridge is powered by the robot, so it cannot be flashed while
            # it is installed -- this is for a board on the FHEM machine's USB.
            #
            # An image may be named first, but it rarely has to be: without one
            # the attribute decides, and without that the image this project
            # builds is fetched. What is usually wanted here is the network:
            #   set <dev> flashESP "My WLAN" "secret phrase"
            my @rest = @args;
            my $image = "";
            if (defined($rest[0])
                && ($rest[0] =~ m/^https?:\/\//i || $rest[0] =~ m/\.bin$/i
                    || -e $rest[0])) {
                $image = shift(@rest);
            }
            $image = AttrVal($name, "espImage", $NeatoLocal_imageURL)
                if ($image eq "");

            my ($ssid, $psk) = NeatoLocal_SplitCredentials(@rest);

            return "usage: set $name flashESP [<image or url>] "
                 . "[<ssid> <password>]\n"
                 . "Quote values containing spaces: flashESP \"My WLAN\" \"secret\""
                if (defined($ssid) && !defined($psk));

            if (defined($ssid) && !defined(NeatoLocal_SeedBlob($ssid, $psk))) {
                return "the network name must be 1 to 32 characters and the "
                     . "password at most 64";
            }

            $hash->{helper}{flashRunning} = time();
            readingsSingleUpdate($hash, "lastFlash",
                                 defined($ssid)
                                 ? "running, with '$ssid' and a "
                                   . length($psk) . " character password"
                                 : "running", 1);
            Log3 $name, 3, "NeatoLocal ($name) - flashing $image to $port"
                         . (defined($ssid) ? " with network '$ssid', "
                                           . length($psk) . " character password"
                                           : "");

            BlockingCall("NeatoLocal_FlashBlocking",
                         "$name|$port|$image|"
                       . (defined($ssid) ? "$ssid|$psk" : "|"),
                         "NeatoLocal_FlashDone", 420,
                         "NeatoLocal_FlashAborted", $hash);
            InternalTimer(gettimeofday() + 450, "NeatoLocal_FlashWatch", $hash);
            return undef;
        }

        my ($ssid, $psk) = NeatoLocal_SplitCredentials(@args);

        return "usage: set $name wifiESP <ssid> <password>\n"
             . "Quote values containing spaces: wifiESP \"My WLAN\" \"secret\""
            if (!defined($ssid) || !defined($psk));

        $hash->{helper}{flashRunning} = time();

        # What arrived here, not what was typed. Quoting, and whatever FHEM
        # does to a command line before a module sees it, can differ -- and a
        # password that lost a character on the way is otherwise invisible
        # until the router refuses it. The password itself stays out of the
        # log; its length is what makes the difference visible.
        Log3 $name, 3, "NeatoLocal ($name) - sending credentials to $port: "
                     . "ssid '$ssid', " . length($psk) . " character password";
        readingsSingleUpdate($hash, "lastFlash",
                             "wifi: sending '$ssid', " . length($psk)
                           . " character password", 1);

        BlockingCall("NeatoLocal_ProvisionBlocking", "$name|$port|$ssid|$psk",
                     "NeatoLocal_ProvisionDone", 300,
                     "NeatoLocal_FlashAborted", $hash);
        InternalTimer(gettimeofday() + 330, "NeatoLocal_FlashWatch", $hash);
        return undef;
    }

    if ($cmd eq "otaESP") {
        return "an update over the air needs a bridge on the network, not an "
             . "HTTP gateway" if ($hash->{TRANSPORT} eq "http");

        my $since = $hash->{helper}{flashRunning};
        if ($since) {
            my $age = time() - ($since =~ m/^\d+$/ ? $since : 0);
            return "a flash or provisioning run has been going for $age s. "
                 . "It is given up on after $NeatoLocal_flashLock s."
                if ($age < $NeatoLocal_flashLock);
        }

        # An address may be given for a bridge that has moved; otherwise the one
        # the device already talks to is the right one.
        my @rest = grep { lc($_) ne "force" } @args;
        my $force = (grep { lc($_) eq "force" } @args) ? 1 : 0;

        my $ip;
        $ip = shift(@rest) if (defined($rest[0])
                            && $rest[0] =~ m/^\d+\.\d+\.\d+\.\d+$/);
        $ip = NeatoLocal_BridgeIp($hash) if (!defined($ip));

        return "no address for the bridge. Give one: set $name otaESP "
             . "<ip> [<image>]"
            if (!defined($ip));

        my $image = defined($rest[0]) && $rest[0] ne "" ? $rest[0]
                  : AttrVal($name, "espAppImage", $NeatoLocal_appURL);

        $hash->{helper}{flashRunning} = time();
        readingsSingleUpdate($hash, "lastFlash", "ota running to $ip", 1);
        Log3 $name, 3, "NeatoLocal ($name) - updating the bridge at $ip "
                     . "over the air from $image";

        BlockingCall("NeatoLocal_OtaBlocking",
                     "$name|$ip|$NeatoLocal_otaPort|$force|$image",
                     "NeatoLocal_OtaDone", 300,
                     "NeatoLocal_FlashAborted", $hash);
        InternalTimer(gettimeofday() + 330, "NeatoLocal_FlashWatch", $hash);
        return undef;
    }

    if ($cmd eq "buildPlan") {
        return NeatoLocal_PlanStart($hash, 1);
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
        my $force = (defined($args[1]) && lc($args[1]) eq "force") ? 1 : 0;

        return "usage: set $name startCleaning [house|spot|explore|persistent]"
            if ($mode !~ m/^(house|spot|explore|persistent)$/);

        # Both of these are described by the robot's own help as equivalent to
        # starting that run from the Smart App, and the app is what the shutdown
        # took away. Observed on a D6: the command is accepted, the robot raises
        # UI_ALERT_ACQUIRING_PERSISTENT_MAP_IDS, does not move -- and afterwards
        # accepts every further cleaning command without acting on it, until it
        # is switched off and on again. Refusing that is worth more than offering
        # a mode that costs the robot's next run.
        return "'$mode' asks the robot for a run that the Smart App used to "
             . "start, and it then waits for map IDs that nothing delivers any "
             . "more. It does not clean, and it stops reacting to further "
             . "cleaning commands until it is switched off and on again. Use "
             . "'house' or 'spot'. To try it anyway: "
             . "set $name startCleaning $mode force"
            if (($mode eq "explore" || $mode eq "persistent") && !$force);

        my ($serialCmd, $err) = NeatoLocal_MappedCmd($hash,
            ($mode eq "house") ? "startCleaning" : $mode);
        return $err if (defined($err));

        # some firmware refuses to clean while a USB host is attached
        Log3 $name, 3, "NeatoLocal ($name) - cleaning may be refused while a USB "
                     . "host is attached, see docs/hardware.md"
            if ($hash->{TRANSPORT} eq "serial");

        $hash->{helper}{assumeCleaning} = 1;
        NeatoLocal_UpdateState($hash);

        # The robot does not keep the navigation mode across runs, so it has to
        # be set again right before the run it should apply to.
        my $navMode = ReadingsVal($name, "navigationMode", "");
        NeatoLocal_Enqueue($hash, "SetNavigationMode $navMode",
                           \&NeatoLocal_ParseGeneric)
            if ($navMode ne "" && $mode eq "house"
                && grep { $_ eq $navMode } @NeatoLocal_navModes);

        NeatoLocal_Enqueue($hash, $serialCmd, \&NeatoLocal_ParseGeneric);
        NeatoLocal_Enqueue($hash, "GetErr", \&NeatoLocal_ParseErr);
        return undef;
    }

    if ($cmd eq "clearError") {
        NeatoLocal_Enqueue($hash, "GetErr Clear", \&NeatoLocal_ParseGeneric);

        # "Clear - Dismiss the reported error" is what the robot's own help says,
        # and it means it: an alert survives GetErr Clear and then sits there for
        # good, which reads like a robot nobody can reset. SetUIError is
        # undocumented -- it comes from OpenNeato's reverse engineering -- and
        # dismisses both. A robot that does not know it answers with an error,
        # which costs one line in lastResponse and nothing else.
        NeatoLocal_Enqueue($hash, "SetUIError clearall", \&NeatoLocal_ParseGeneric);
        NeatoLocal_Enqueue($hash, "GetErr", \&NeatoLocal_ParseErr);
        return undef;
    }

    if (defined($NeatoLocal_settingCmds{$cmd})) {
        my $arg = defined($args[0]) ? lc($args[0]) : "";
        return "usage: set $name $cmd <on|off>" if ($arg !~ m/^(on|off)$/);

        NeatoLocal_Enqueue($hash,
            "SetUserSettings " . $NeatoLocal_settingCmds{$cmd} . " " . uc($arg),
            \&NeatoLocal_ParseGeneric);

        # read it back, so the reading reflects the robot rather than our hope
        NeatoLocal_Enqueue($hash, "GetUserSettings", \&NeatoLocal_ParseUserSettings);
        return undef;
    }

    if ($cmd eq "navigationMode") {
        my $mode = defined($args[0]) ? ucfirst(lc($args[0])) : "";
        return "usage: set $name navigationMode <"
             . join("|", @NeatoLocal_navModes) . ">"
            if (!grep { $_ eq $mode } @NeatoLocal_navModes);

        # The console has no GetNavigationMode, so the robot can never tell us
        # which mode is active. The reading is therefore what FHEM last set --
        # it survives a restart in the statefile and is re-applied before every
        # house cleaning, which is how the mode actually takes effect.
        readingsSingleUpdate($hash, "navigationMode", $mode, 1);

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

##############################################################################
# flashing and provisioning the WiFi bridge
##############################################################################

# esptool goes by three different names depending on how it was installed.
sub NeatoLocal_FindEsptool() {
    foreach my $candidate ("esptool.py", "esptool") {
        my $path = qx(command -v $candidate 2>/dev/null);
        chomp($path);
        return $path if ($path ne "");
    }

    my $rc = system("python3 -c 'import esptool' >/dev/null 2>&1");
    return "python3 -m esptool" if ($rc == 0);

    return "";
}

# Which serial ports are there, and what is behind them? Both the robot and an
# ESP32-C3 show up as /dev/ttyACM*, so the bare device name says nothing about
# which is which -- the stable by-id names do.
sub NeatoLocal_ScanSerialPorts(;$$) {
    my ($byid, $devdir) = @_;
    $byid   = "/dev/serial/by-id" if (!defined($byid));
    $devdir = "/dev"              if (!defined($devdir));

    my @found;
    my %seen;

    if (opendir(my $dh, $byid)) {
        foreach my $entry (sort readdir($dh)) {
            next if ($entry =~ m/^\.\.?$/);
            my $link = readlink("$byid/$entry");
            my $target = $link;
            if (defined($target)) {
                $target =~ s/.*\///;    # ../../ttyACM0 -> ttyACM0
                $seen{$target} = 1;
            }
            $target = defined($target) ? "$devdir/$target" : "?";

            # Most specific first: an ESP32's own name mentions a serial
            # device too, so a plain "usb serial" test would swallow it.
            my $what = "unknown";
            if ($entry =~ m/espressif|jtag.serial.debug/i) {
                $what = "ESP32 (native USB)";
            }
            elsif ($entry =~ m/neato|vorwerk|botvac/i) {
                $what = "Neato robot";
            }
            elsif ($entry =~ m/ch340|1a86|cp210|10c4|ft232|0403|pl2303|usb.?serial/i) {
                $what = "USB-serial adapter";
            }

            push @found, { port => $target, id => "$byid/$entry", what => $what };
        }
        closedir($dh);
    }

    # ports without a by-id entry still deserve a mention
    if (opendir(my $dh, $devdir)) {
        foreach my $entry (sort readdir($dh)) {
            next if ($entry !~ m/^tty(ACM|USB)\d+$/);
            next if ($seen{$entry});
            push @found, { port => "$devdir/$entry", id => "-", what => "unknown" };
        }
        closedir($dh);
    }

    return \@found;
}

sub NeatoLocal_FormatSerialPorts($) {
    my ($ports) = @_;

    return "No serial ports found. Plug the board in, then look at "
         . "'dmesg | tail' -- a port that never appears is usually a "
         . "charge-only cable."
        if (!@$ports);

    my $out = "";
    foreach my $p (@$ports) {
        $out .= sprintf("%-16s %s\n", $p->{port}, $p->{what});
        $out .= sprintf("%-16s %s\n", "", $p->{id}) if ($p->{id} ne "-");
    }

    $out .= "\nThe by-id name stays the same across reboots and does not care "
          . "which USB socket is used, so it is the better thing to put into "
          . "espPort or a define.\n";

    return $out;
}

# Refuse to write something that is not an ESP firmware image. Every such image
# starts with the magic byte 0xE9, and a merged one for the C3 is around a
# megabyte -- a truncated download or an HTML error page fails both tests.
sub NeatoLocal_CheckImage($) {
    my ($path) = @_;

    return "image not readable: $path" if (!-r $path);

    my $size = -s $path;
    return "image is empty: $path" if (!$size);
    return "image is far too small for a firmware ($size bytes): $path"
        if ($size < 100000);

    my $fh;
    return "cannot open $path" if (!open($fh, "<", $path));
    binmode($fh);
    my $read = read($fh, my $head, 1);
    close($fh);

    return "not a firmware image, the 0xE9 magic is missing: $path"
        if (!$read || ord($head) != 0xE9);

    return undef;
}

# Runs in a forked child, so a flash of half a minute does not stall FHEM.
# Wait for a freshly started board and ask where it ended up. The USB port goes
# away and comes back with the restart, so it is reopened each round rather than
# held open.
#
# The board may need two goes at the network -- one on the radio as the reset
# left it, one after bringing it down properly -- and then there is the fallback
# to the access point. Together that is well over half a minute, so the window
# has to be wide enough not to give up while the board is still working.
#
# Runs inside BlockingCall only: it sleeps.
sub NeatoLocal_AwaitBridge($;$) {
    my ($port, $budget) = @_;
    $budget = 180 if (!defined($budget));

    my $deadline = time() + $budget;
    my $reply = "";
    my $answered = $port;

    while (time() < $deadline) {
        sleep(3);

        # esptool resets the board, and a board with native USB drops off the
        # bus while it restarts. It does not have to come back under the same
        # name -- so a port that stays missing is looked for rather than waited
        # out, which is otherwise a full minute spent on a device that has
        # simply been renumbered.
        my $use = $port;
        if (!-e $use) {
            my $moved = NeatoLocal_FindEspPort();
            next if (!defined($moved));
            $use = $moved;
        }

        system("stty -F " . quotemeta($use) . " 115200 cs8 -cstopb -parenb "
             . "-crtscts -ixon -ixoff raw -echo >/dev/null 2>&1");

        my $fh;
        next if (!open($fh, "+<", $use));
        $answered = $use;

        my $old = select($fh); $| = 1; select($old);
        print $fh "\ninfo\n";

        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm(8);
            while (my $line = <$fh>) {
                $reply .= $line;
                last if ($line =~ m/^mode\s+\S+/);
            }
            alarm(0);
        };
        alarm(0);
        close($fh);

        # 0.0.0.0 is what the board reports while it is still trying. Taking it
        # for an address ends the wait at the very moment there is nothing to
        # report yet.
        last if ($reply =~ m/\bip\s+(\d+\.\d+\.\d+\.\d+)/ && $1 ne "0.0.0.0");
        $reply = "";
    }

    $reply =~ s/\s+/ /g;
    $reply =~ s/^\s+|\s+$//g;

    my ($ip)   = ($reply =~ m/\bip\s+(\d+\.\d+\.\d+\.\d+)/);
    my ($mode) = ($reply =~ m/\bmode\s+(\w+)/);

    $ip = undef if (defined($ip) && $ip eq "0.0.0.0");

    return ($ip, $mode, $reply, $answered);
}

# The board after a reset, when the configured port is gone. Only consulted in
# that case, so a wrong guess cannot redirect a working setup.
sub NeatoLocal_FindEspPort() {
    my $ports = NeatoLocal_ScanSerialPorts();

    foreach my $p (@$ports) {
        return $p->{port} if ($p->{what} =~ m/^ESP32/);
    }
    return undef;
}

# Attribute values arrive with whatever whitespace was typed around them, and a
# port name with a trailing space fails every -e test for a reason nobody can
# see in a list output.
sub NeatoLocal_EspPort($) {
    my ($name) = @_;

    my $port = AttrVal($name, "espPort", "/dev/ttyACM0");
    $port =~ s/^\s+|\s+$//g;
    return $port;
}

sub NeatoLocal_SlurpFile($) {
    my ($path) = @_;

    my $fh;
    return "" if (!defined($path) || !-e $path || !open($fh, "<", $path));
    local $/;
    my $content = <$fh>;
    close($fh);
    return defined($content) ? $content : "";
}

# FHEM has already split the arguments, so they are rejoined and parsed again:
# both a network name and a password may contain spaces, and then they have to
# be quoted -- set <dev> flashESP "My WLAN" "secret phrase". Whatever follows
# the name is the password, spaces and all.
#
# Returns nothing when there is no name, and the name alone when there is no
# password, so the caller can tell the two apart.
sub NeatoLocal_SplitCredentials(@) {
    my (@args) = @_;

    my $line = join(" ", @args);
    my @parts;
    while ($line =~ m/\G\s*(?:"([^"]*)"|(\S+))/gc) {
        push @parts, defined($1) ? $1 : $2;
    }

    return (undef, undef) if (!@parts);

    my $ssid = shift(@parts);
    return ($ssid, undef) if (!@parts);

    return ($ssid, join(" ", @parts));
}

# The credentials block the firmware picks up on its first boot. Written to the
# storage partition rather than into the application image: the image carries a
# SHA-256 that the bootloader checks, so patching bytes into it would stop the
# board from starting at all.
#
# Layout, matching SEED_* in the firmware: magic, the two lengths, then the
# fields at fixed positions. Padded with 0xFF, the value erased flash already
# has.
sub NeatoLocal_SeedBlob($$) {
    my ($ssid, $psk) = @_;

    return undef if (!defined($ssid) || length($ssid) < 1 || length($ssid) > 32);
    return undef if (!defined($psk) || length($psk) > 64);

    my $blob = "NEATOSEED1"
             . chr(length($ssid)) . chr(length($psk))
             . pack("a32", $ssid)
             . pack("a64", $psk);

    return $blob . ("\xFF" x (128 - length($blob)));
}

# The offset comes from the metadata CI writes beside the image, which reads it
# out of the partition table inside that very image. A number kept here instead
# would be right only until somebody changes the partition scheme.
sub NeatoLocal_SeedOffset($) {
    my ($text) = @_;

    return undef if (!defined($text));
    my ($offset) = ($text =~ m/^seed offset:\s*(0x[0-9a-fA-F]+)/m);
    return $offset;
}

# Where the bridge can be reached, for an update that cannot use a cable. The
# reading is preferred: it was written by the run that put the bridge there.
sub NeatoLocal_BridgeIp($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $fromReading = ReadingsVal($name, "bridgeAddress", "");
    return $fromReading if ($fromReading =~ m/^\d+\.\d+\.\d+\.\d+$/);

    my $addr = $hash->{DeviceName};
    $addr = $hash->{DEF} if (!defined($addr) || $addr eq "");
    return undef if (!defined($addr));

    my ($ip) = ($addr =~ m/(\d+\.\d+\.\d+\.\d+)/);
    return $ip;
}

# Which version the bridge is running, read off its status page. Only used to
# refuse an update that would strand it, so a page that cannot be read is not an
# error -- it just means the question stays open.
sub NeatoLocal_BridgeVersion($) {
    my ($ip) = @_;

    my $page = qx(curl -fsS --max-time 5 http://$ip/ 2>/dev/null);
    return undef if (!defined($page) || $page eq "");

    my ($version) = ($page =~ m/neato_bridge\s+(\d+\.\d+\.\d+)/);
    return $version;
}

# Before 0.4.0 the credentials were compiled into the binary: no NVS, no setup
# access point. An update replaces that binary, and with it the only copy of the
# network -- on a bridge glued inside a robot, where nobody can hold a cable to
# it. Worth stopping for, even though the way back exists.
sub NeatoLocal_OtaWouldStrand($) {
    my ($version) = @_;

    return 0 if (!defined($version));
    my ($major, $minor, $patch) = split(/\./, $version);
    return 0 if (!defined($minor));

    return ($major == 0 && $minor < 4) ? 1 : 0;
}

# Push a firmware image to the bridge over the air. Every version of the bridge
# has carried ArduinoOTA, including the ones installed in a robot before FHEM
# could flash anything -- and that is the point: a bridge glued inside a robot
# cannot be reached with a USB cable.
#
# The wire format is taken from the reference client (espota.py) and from the
# device side (ArduinoOTA.cpp), not from memory:
#
#   1. listen on a TCP port
#   2. send one UDP line "<command> <tcp port> <size> <md5>" to the OTA port
#   3. the device answers "OK", or "AUTH <nonce>" when a password is set
#   4. the device opens a TCP connection back to the announced port
#   5. the image goes over in pieces; for each piece the device answers with the
#      number of bytes it wrote, as decimal digits
#   6. "OK" arrives once, after the last byte
#
# Written here rather than by calling espota.py: that script belongs to the
# Arduino core, which a FHEM machine has no reason to have installed.
sub NeatoLocal_OtaWork($) {
    my ($string) = @_;
    my ($name, $ip, $otaPort, $force, $image) = split("\\|", $string, 5);

    my $running = NeatoLocal_BridgeVersion($ip);
    if (!$force && NeatoLocal_OtaWouldStrand($running)) {
        return "$name|the bridge runs $running, which keeps the network in its "
             . "firmware image rather than in flash -- this update would replace "
             . "it and leave the bridge without credentials. It then opens the "
             . "access point 'neato-setup', where the network can be entered at "
             . "http://192.168.4.1/ from a phone. No cable needed, but somebody "
             . "has to stand next to the robot. Proceed with: "
             . "set $name otaESP force";
    }

    if ($image =~ m/^https?:\/\//i) {
        my $target = "/tmp/.neato_bridge_ota.bin";
        my $rc = system("curl -fsSL -o " . quotemeta($target) . " "
                      . quotemeta($image) . " 2>/dev/null");
        return "$name|could not download $image" if ($rc != 0);
        $image = $target;
    }

    my $bad = NeatoLocal_CheckImage($image);
    return "$name|$bad" if (defined($bad));

    # Read it once: the checksum has to cover exactly the bytes that are sent.
    my $fh;
    return "$name|cannot open $image" if (!open($fh, "<", $image));
    binmode($fh);
    my $data = do { local $/; <$fh> };
    close($fh);

    my $size = length($data);
    my $md5  = Digest::MD5::md5_hex($data);

    # The device dials back, so we need a port for it to dial.
    my $server = IO::Socket::INET->new(Listen => 1, LocalPort => 0,
                                       Proto => "tcp", ReuseAddr => 1);
    return "$name|cannot open a listening socket: $!" if (!$server);
    my $hostPort = $server->sockport();

    my $udp = IO::Socket::INET->new(PeerAddr => $ip, PeerPort => $otaPort,
                                    Proto => "udp");
    if (!$udp) {
        close($server);
        return "$name|cannot reach $ip:$otaPort: $!";
    }

    my $answer = "";
    foreach my $try (1 .. 5) {
        next if (!$udp->send("0 $hostPort $size $md5\n"));
        next if (!IO::Select->new($udp)->can_read(3));
        $udp->recv($answer, 128);
        last if (length($answer));
    }
    close($udp);

    if ($answer eq "") {
        close($server);
        return "$name|no answer to the update invitation on $ip:$otaPort. Is "
             . "the bridge running, and does its firmware have OTA?";
    }

    $answer =~ s/^\s+|\s+$//g;
    if ($answer =~ m/^AUTH/) {
        close($server);
        return "$name|the bridge wants an OTA password. This module sets none, "
             . "so that image was not built from this project.";
    }
    if ($answer ne "OK") {
        close($server);
        return "$name|the bridge refused the update: $answer";
    }

    if (!IO::Select->new($server)->can_read(20)) {
        close($server);
        return "$name|the bridge took the invitation but never connected back";
    }
    my $client = $server->accept();
    if (!$client) {
        close($server);
        return "$name|could not accept the bridge's connection: $!";
    }

    my $sent = 0;
    my $reply = "";
    my $select = IO::Select->new($client);

    while ($sent < $size) {
        my $wrote = syswrite($client, substr($data, $sent, 1024));
        if (!defined($wrote) || $wrote <= 0) {
            close($client); close($server);
            return "$name|the connection broke after $sent of $size bytes";
        }
        $sent += $wrote;

        # Drain the acknowledgements as they arrive. They are only byte counts,
        # but left unread they fill the buffer and the transfer stalls.
        while ($select->can_read(0)) {
            my $buf = "";
            my $got = sysread($client, $buf, 64);
            last if (!defined($got) || $got == 0);
            $reply .= $buf;
        }
    }

    # The verdict comes after the last byte, and writing a megabyte to flash
    # takes the bridge a moment.
    #
    # Reading until the verdict merely *appears* is not enough: the read window
    # can cut the message in half, and then the reason the bridge gave is lost
    # exactly when it is needed. So once something has arrived, the wait drops to
    # a short quiet period and collects the rest.
    my $deadline = time() + 90;
    while (time() < $deadline) {
        my $quiet = ($reply =~ m/OK|ERROR/i) ? 1 : 5;
        last if (!$select->can_read($quiet));

        my $buf = "";
        my $got = sysread($client, $buf, 256);
        last if (!defined($got) || $got == 0);
        $reply .= $buf;
    }
    close($client);
    close($server);

    return "$name|OK|$sent bytes written, the bridge is restarting"
        if ($reply =~ m/OK/);

    $reply =~ s/^\d+//;      # strip the byte counters, keep the complaint
    $reply =~ s/^\s+|\s+$//g;
    return "$name|the bridge did not accept the image"
         . ($reply ne "" ? ": $reply" : " and said nothing after the transfer");
}

sub NeatoLocal_OtaDone($) {
    my ($string) = @_;
    my ($name, $result, $detail) = split("\\|", $string, 3);
    my $hash = $defs{$name};

    return if (!defined($hash));
    delete $hash->{helper}{flashRunning};
    RemoveInternalTimer($hash, "NeatoLocal_FlashWatch");

    $detail = "" if (!defined($detail));

    if ($result eq "OK") {
        Log3 $name, 3, "NeatoLocal ($name) - update over the air done: $detail";
        readingsSingleUpdate($hash, "lastFlash", "ota ok: $detail", 1);
    }
    else {
        Log3 $name, 1, "NeatoLocal ($name) - update over the air failed: $result";
        readingsSingleUpdate($hash, "lastFlash", "ota: $result", 1);
    }

    return undef;
}

# Blocking.pm hands a worker's result back to FHEM as a single telnet line and
# escapes only quotes and semicolons. A newline in the value therefore breaks
# the command in half: the first part is incomplete Perl, every following line
# becomes its own "Unknown command", and the callback never runs. Nothing shows
# up in the log either, because those errors go back to the child process, which
# is not reading them -- the run simply vanishes, and the device keeps saying
# "running" for ever.
#
# So the flattening happens here, around the workers, rather than at each
# return: esptool alone produces a dozen lines, and the next person to add a
# return would have to know this.
sub NeatoLocal_OneLine($) {
    my ($text) = @_;

    return "" if (!defined($text));
    $text =~ s/\s+$//;
    $text =~ s/[\r\n]+/ -- /g;    # \r too: esptool draws progress with it
    return $text;
}

sub NeatoLocal_FlashBlocking($) {
    return NeatoLocal_OneLine(NeatoLocal_FlashWork($_[0]));
}

sub NeatoLocal_ProvisionBlocking($) {
    return NeatoLocal_OneLine(NeatoLocal_ProvisionWork($_[0]));
}

sub NeatoLocal_OtaBlocking($) {
    return NeatoLocal_OneLine(NeatoLocal_OtaWork($_[0]));
}

sub NeatoLocal_PlanBlocking($) {
    return NeatoLocal_OneLine(NeatoLocal_PlanWork($_[0]));
}

# One floor plan out of the last few recordings, written beside them so the
# FTUI component can load the answer instead of the question.
#
# Everything about it happens in the forked process: the arithmetic lives in
# FHEM/lib/NeatoLocalPlan.pm and is required here rather than at the top of
# this file, so the main process never carries it.
sub NeatoLocal_PlanWork($) {
    my ($string) = @_;
    my ($name, $dir, $device, $sources, $cell, $out) = split("\\|", $string, 6);
    my $started = time();

    # Be polite. On a single core board this runs for minutes next to the rest
    # of the house, and nothing is waiting for the result.
    eval { require POSIX; POSIX::nice(10); };

    my $lib = AttrVal("global", "modpath", ".") . "/FHEM/lib";
    unshift(@INC, $lib) if (!grep { $_ eq $lib } @INC);
    eval { require NeatoLocalPlan; 1; }
        or return "$name|NeatoLocalPlan.pm cannot be loaded from $lib: $@";

    my $dh;
    opendir($dh, $dir) or return "$name|$dir cannot be read: $!";
    my @names = sort { $b cmp $a }
                grep { m/^\Q$device\E-.*\.jsonl$/ } readdir($dh);
    closedir($dh);

    return "$name|no recordings of $device in $dir -- set trackRuns to 1 to record them"
        if (!scalar(@names));

    @names = @names[0 .. $sources - 1] if (scalar(@names) > $sources);

    my @surveys;
    my @used;
    for my $file (@names) {
        my $session = NeatoLocalPlan::read_session("$dir/$file");
        next if (!defined($session) || !scalar(@{ $session->{scans} }));
        push(@surveys, NeatoLocalPlan::survey($session, { cell => $cell }));
        push(@used, $file);
    }

    return "$name|none of the " . scalar(@names) . " recordings has scans -- "
         . "without mapInterval only the track is recorded, and a track is not a plan"
        if (!scalar(@surveys));

    my $plan = NeatoLocalPlan::merge_plan(\@surveys, { cell => $cell });

    my @stamp = gmtime(time());
    my $built = sprintf("%04d-%02d-%02dT%02d:%02d:%02d.000Z",
                        $stamp[5] + 1900, $stamp[4] + 1, $stamp[3],
                        $stamp[2], $stamp[1], $stamp[0]);

    my $fh;
    open($fh, ">", "$out.new") or return "$name|$out cannot be written: $!";
    print $fh NeatoLocalPlan::as_json($plan, \@used, $built);
    close($fh);
    # Into place in one step: a panel polling the file must never catch it
    # half written.
    rename("$out.new", $out) or return "$name|$out cannot be replaced: $!";

    # The grades of the runs that were left out travel back rather than just
    # their number. The threshold they were measured against is an assumption,
    # and a run that is quietly dropped shows up as nothing but a smaller
    # planRuns than expected.
    my @dropped = sort { $b <=> $a } map { $_->{score} } @{ $plan->{rejected} };

    return sprintf("%s|OK|%s|%d|%d|%s|%d", $name, $out,
                   scalar(@{ $plan->{cells} }), $plan->{runs},
                   join(",", map { sprintf("%.2f", $_) } @dropped),
                   time() - $started);
}

# Start a plan run, from "set buildPlan" or after a cleaning run.
sub NeatoLocal_PlanStart($$) {
    my ($hash, $manual) = @_;
    my $name = $hash->{NAME};

    if ($hash->{helper}{planRunning}) {
        my $age = time() - $hash->{helper}{planRunning};
        if ($age < $NeatoLocal_planLock) {
            return $manual ? "a plan has been computed for ${age}s already" : undef;
        }
        Log3 $name, 2, "NeatoLocal ($name) - the last plan run left its lock "
                     . "behind ${age}s ago, taking it over";
    }

    my $dir     = AttrVal($name, "trackDir", "./www/neato");
    my $sources = AttrVal($name, "planSources", 8);
    my $cell    = AttrVal($name, "planCell", 0.10);

    if ($sources !~ m/^\d+$/ || $sources < 1) {
        my $why = "planSources is '$sources', expected how many recordings go in";
        Log3 $name, 1, "NeatoLocal ($name) - $why";
        return $manual ? $why : undef;
    }
    if ($cell !~ m/^\d*\.?\d+$/ || $cell <= 0) {
        my $why = "planCell is '$cell', expected a cell size in metres such as 0.10";
        Log3 $name, 1, "NeatoLocal ($name) - $why";
        return $manual ? $why : undef;
    }

    my $out = "$dir/plan-$name.json";
    $hash->{helper}{planRunning} = time();
    Log3 $name, 3, "NeatoLocal ($name) - computing the plan from up to $sources "
                 . "recordings in $dir, this takes minutes";

    BlockingCall("NeatoLocal_PlanBlocking",
                 "$name|$dir|$name|$sources|$cell|$out",
                 "NeatoLocal_PlanDone", $NeatoLocal_planTimeout,
                 "NeatoLocal_PlanAborted", $hash);

    return undef;
}

sub NeatoLocal_PlanDone($) {
    my ($string) = @_;
    my ($name, $result, $file, $cells, $runs, $dropped, $seconds)
        = split("\\|", $string, 7);
    my $hash = $defs{$name};

    return if (!defined($hash));
    delete $hash->{helper}{planRunning};

    if (!defined($result) || $result ne "OK") {
        my $why = defined($result) ? $result : "no result";
        Log3 $name, 1, "NeatoLocal ($name) - no plan: $why";
        readingsSingleUpdate($hash, "planState", "failed: $why", 1);
        return undef;
    }

    # With the grades, not just the count: the threshold a run was measured
    # against is an assumption, and these numbers are what would settle it. A
    # 0.44 that was dropped says something quite different from a 0.05.
    my @scores = grep { length($_) } split(/,/, defined($dropped) ? $dropped : "");
    my $state = "ok";
    $state .= sprintf(", %d did not fit (%s)", scalar(@scores), join(", ", @scores))
        if (scalar(@scores));

    Log3 $name, 3, "NeatoLocal ($name) - plan written to $file: $cells cells "
                 . "from $runs recordings"
                 . (scalar(@scores) ? ", " . scalar(@scores) . " did not fit: "
                                    . join(", ", @scores) : "")
                 . ", ${seconds}s";

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "planFile", $file);
    readingsBulkUpdate($hash, "planCells", $cells);
    readingsBulkUpdate($hash, "planRuns", $runs);
    readingsBulkUpdate($hash, "planState", $state);
    readingsEndUpdate($hash, 1);

    return undef;
}

sub NeatoLocal_PlanAborted($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    delete $hash->{helper}{planRunning};
    Log3 $name, 1, "NeatoLocal ($name) - the plan run was cut short after "
                 . "${NeatoLocal_planTimeout}s. Fewer recordings in planSources, "
                 . "or a bigger planCell, make it shorter.";
    readingsSingleUpdate($hash, "planState", "timed out", 1);

    return undef;
}

sub NeatoLocal_FlashWork($) {
    my ($string) = @_;
    my ($name, $port, $image, $ssid, $psk) = split("\\|", $string, 5);

    $ssid = undef if (defined($ssid) && $ssid eq "");
    $psk = "" if (!defined($psk));

    my $tool = NeatoLocal_FindEsptool();
    return "$name|esptool not found. Install it with 'pip3 install esptool' or "
         . "the distribution package of the same name."
        if ($tool eq "");

    # A URL is fetched first, so the image does not have to be downloaded by
    # hand before it can be written. The metadata file beside it comes along:
    # it names the partition the credentials block belongs in.
    my $meta = "";
    if ($image =~ m/^https?:\/\//i) {
        my $metaUrl = $image;
        $metaUrl =~ s/\.bin$/.txt/;

        my $target = "/tmp/.neato_bridge_flash.bin";
        my $rc = system("curl -fsSL -o " . quotemeta($target) . " "
                      . quotemeta($image) . " 2>/dev/null");
        return "$name|could not download $image" if ($rc != 0);

        if ($metaUrl ne $image) {
            my $metaFile = "/tmp/.neato_bridge_flash.txt";
            if (system("curl -fsSL -o " . quotemeta($metaFile) . " "
                     . quotemeta($metaUrl) . " 2>/dev/null") == 0) {
                $meta = NeatoLocal_SlurpFile($metaFile);
            }
        }
        $image = $target;
    }
    else {
        my $metaFile = $image;
        $metaFile =~ s/\.bin$/.txt/;
        $meta = NeatoLocal_SlurpFile($metaFile) if ($metaFile ne $image);
    }

    # Refuse before writing rather than halfway through: a board with the image
    # on it but no credentials needs the console after all, which is the detour
    # this is meant to avoid.
    my $seedOffset;
    if (defined($ssid)) {
        $seedOffset = NeatoLocal_SeedOffset($meta);
        return "$name|the image does not say where the credentials block goes "
             . "(no 'seed offset' in the metadata beside it). Flash without "
             . "credentials and use 'set $name wifiESP' instead."
            if (!defined($seedOffset));
    }

    my $bad = NeatoLocal_CheckImage($image);
    return "$name|$bad" if (defined($bad));

    return "$name|serial port not found: $port" if (!-e $port);
    return "$name|no write access to $port -- is the FHEM user in the dialout "
         . "group?" if (!-w $port);

    my $cmd = "$tool --chip esp32c3 --port " . quotemeta($port)
            . " write_flash 0x0 " . quotemeta($image) . " 2>&1";
    my $out = qx($cmd);
    my $rc  = $? >> 8;

    # The credentials go into their own partition in a second pass. They cannot
    # ride along inside the image: that carries a SHA-256 the bootloader checks,
    # so anything written into it stops the board from starting.
    if ($rc == 0 && defined($ssid)) {
        my $blob = NeatoLocal_SeedBlob($ssid, $psk);
        return "$name|the network name or password does not fit the credentials "
             . "block" if (!defined($blob));

        my $seedFile = "/tmp/.neato_bridge_seed.bin";
        my $fh;
        return "$name|cannot write $seedFile" if (!open($fh, ">", $seedFile));
        binmode($fh);
        print $fh $blob;
        close($fh);

        my $seedCmd = "$tool --chip esp32c3 --port " . quotemeta($port)
                    . " write_flash " . quotemeta($seedOffset) . " "
                    . quotemeta($seedFile) . " 2>&1";
        my $seedOut = qx($seedCmd);
        my $seedRc = $? >> 8;

        # The password does not stay on disk beyond the write.
        unlink($seedFile);

        $out .= "\n" . $seedOut;
        $rc = $seedRc if ($seedRc != 0);

        # Writing the credentials is only half the job: without an address the
        # module has a bridge on the network and no way to reach it. The board
        # is still on this USB port, so it can simply be asked.
        if ($seedRc == 0) {
            my ($ip, $mode, $reply) = NeatoLocal_AwaitBridge($port);

            if (!defined($ip) || (defined($mode) && lc($mode) eq "ap")) {
                my $status = NeatoLocal_ConsoleAsk($port, "wifi status",
                                                  qr/^reason\s/m, 10);
                my $scan = NeatoLocal_ConsoleAsk($port, "wifi scan",
                                                 qr/OK scan done/, 30);
                return "$name|written, but the bridge did not reach the network||"
                     . NeatoLocal_ScanVerdict($ssid, $scan, $status);
            }

            # The address goes first: esptool's output may contain the
            # separator, and everything after the third one is that output.
            return "$name|OK|$ip|$out";
        }
    }

    # keep the tail: the interesting part of an esptool failure is at the end
    $out =~ s/\s+$//;
    my @lines = split(/\n/, $out);
    $out = join(" | ", @lines[-6 .. -1]) if (@lines > 6);
    $out = join(" | ", @lines) if (@lines <= 6);

    return "$name|" . (($rc == 0) ? "OK||$out" : "failed (rc $rc)||$out");
}

sub NeatoLocal_FlashDone($) {
    my ($string) = @_;
    my ($name, $result, $ip, $detail) = split("\\|", $string, 4);
    my $hash = $defs{$name};

    return if (!defined($hash));
    delete $hash->{helper}{flashRunning};
    RemoveInternalTimer($hash, "NeatoLocal_FlashWatch");

    $detail = "" if (!defined($detail));
    $ip = "" if (!defined($ip));

    if ($result eq "OK") {
        Log3 $name, 3, "NeatoLocal ($name) - flashing finished: $detail";

        if ($ip ne "") {
            readingsBeginUpdate($hash);
            readingsBulkUpdate($hash, "lastFlash", "ok, bridge at $ip");
            readingsBulkUpdate($hash, "bridgeAddress", $ip);
            readingsEndUpdate($hash, 1);
            NeatoLocal_AdoptBridgeAddress($hash, $ip);
        }
        else {
            readingsSingleUpdate($hash, "lastFlash", "ok", 1);
        }
    }
    else {
        Log3 $name, 1, "NeatoLocal ($name) - flashing $result: $detail";
        readingsSingleUpdate($hash, "lastFlash", "$result: $detail", 1);
    }

    return undef;
}

# Neither Done nor Aborted is guaranteed: a result that cannot be delivered
# leaves the job marked finished, so Blocking.pm never calls the abort function
# either. Without this the reading says "running" until FHEM restarts.
sub NeatoLocal_FlashWatch($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return undef if (!$hash->{helper}{flashRunning});

    delete $hash->{helper}{flashRunning};
    Log3 $name, 1, "NeatoLocal ($name) - the background run never reported back";
    readingsSingleUpdate($hash, "lastFlash",
                         "no answer from the background run", 1);
    return undef;
}

sub NeatoLocal_FlashAborted($) {
    my ($hash) = @_;
    my $name = (ref($hash) eq "HASH") ? $hash->{NAME} : $hash;

    delete $defs{$name}{helper}{flashRunning} if (defined($defs{$name}));
    RemoveInternalTimer($defs{$name}, "NeatoLocal_FlashWatch")
        if (defined($defs{$name}));
    Log3 $name, 1, "NeatoLocal ($name) - flashing timed out";
    readingsSingleUpdate($defs{$name}, "lastFlash", "timeout", 1)
        if (defined($defs{$name}));

    return undef;
}

# Sends the credentials to the freshly flashed board over its USB port, using
# the little configuration console the firmware provides. One line per value so
# both may contain spaces.
# The disconnect codes both SDKs agree on. Unknown codes keep their number
# rather than being dressed up as an explanation.
my %NeatoLocal_reasons = (
    2   => "authentication expired",
    4   => "association expired",
    15  => "password refused",
    200 => "beacon lost",
    201 => "network not found",
    202 => "authentication refused",
    203 => "association refused",
    204 => "handshake timed out",
    205 => "connection failed",
);

sub NeatoLocal_ReasonText($) {
    my ($reason) = @_;
    return $NeatoLocal_reasons{$reason} if (defined($NeatoLocal_reasons{$reason}));
    return "unknown";
}

# Turn the board's scan into the one sentence that moves the search forward.
# A name that is not on the air cannot be reached with any password, and a name
# that is on the air rules the name out -- naming which of the two it is beats
# handing back both possibilities every time.
sub NeatoLocal_ScanVerdict($$;$) {
    my ($ssid, $scan, $status) = @_;

    $scan = "" if (!defined($scan));
    $status = "" if (!defined($status));

    my @seen;
    my %enc;
    while ($scan =~ m/^scan:\s+(.*?)\s\s+(-?\d+) dBm\s+ch (\d+)(?:\s+enc (\S+))?/mg) {
        my ($net, $dbm, $ch, $mode) = ($1, $2, $3, $4);
        push @seen, "$net ($dbm dBm, ch $ch" . (defined($mode) ? ", $mode" : "") . ")";
        $enc{$mode} = 1 if (defined($mode) && $net eq $ssid);
    }
    my $list = @seen ? " In range: " . join(", ", @seen) . "." : "";

    # Refused during authentication, on a network that runs WPA3 or the mixed
    # mode: that pairing is a known sore point, and it is worth naming before
    # anybody goes looking through the router's device list again.
    my $wpa3 = (grep { m/WPA3/ } keys %enc) ? " '$ssid' runs " . join("/", sort keys %enc)
             . " -- the WPA3 handshake is the first thing to rule out here; "
             . "setting the access point to WPA2 for one attempt settles it."
             : "";

    # The board's own reason code beats every inference drawn from the scan:
    # it comes from the association attempt itself.
    my ($reason) = ($status =~ m/^reason\s+(\d+)/m);
    if (defined($reason) && $reason > 0) {
        my ($mac) = ($status =~ m/^mac\s+(\S+)/m);
        my ($len) = ($status =~ m/^psk\s+(\d+) characters/m);

        # What the board received, so a password mangled on the way here can be
        # spotted by counting rather than by trying again.
        my $got = defined($len)
                ? " The board received a $len character password"
                  . (defined($mac) ? " and reports MAC $mac." : ".")
                : (defined($mac) ? " The board's MAC is $mac." : "");

        # Only the handshake codes actually accuse the password. Reason 2 is
        # "previous authentication no longer valid", which a router also sends
        # when it declines a client for its own reasons -- saying "wrong
        # password" there sends people to check what is already correct.
        return "'$ssid' refused the password (reason $reason, the handshake "
             . "timed out).$got$list"
            if ($reason == 15 || $reason == 204);

        return "'$ssid' broke off the authentication (reason 2). This is not "
             . "proof of a wrong password: a router sends the same when it "
             . "declines a client -- MAC filter, client limit, or a band it "
             . "steers away from. Check whether the router admits this board."
             . "$got$list"
            if ($reason == 2);

        return "'$ssid' turned the board away (reason $reason: "
             . NeatoLocal_ReasonText($reason) . "), during authentication and "
             . "thus before the password is ever checked.$wpa3$got$list"
            if ($reason == 202 || $reason == 203);

        return "the board did not find '$ssid' on the air (reason $reason). "
             . "Check the name, and that the 2.4 GHz band carries it.$list"
            if ($reason == 201);

        return "the board could not join '$ssid' (reason $reason: "
             . NeatoLocal_ReasonText($reason) . ").$got$list";
    }

    return "the name '$ssid' is not on the air on 2.4 GHz where the board is, "
         . "so no password gets it onto the network. Check whether that name "
         . "belongs to the 5 GHz band only, or is hidden.$list"
        if ($scan =~ m/is NOT among them/);

    return "credentials stored, but the board could not join '$ssid' although "
         . "it is on the air -- so it is the password or the encryption, not "
         . "the name.$list"
        if ($scan =~ m/configured network '.*' is there/);

    # "The scan found nothing" and "the scan did not run" look the same in the
    # result and mean opposite things, so they are not merged here.
    my $hint = $list                    ? $list
             : $scan =~ m/scan: failed/ ? " The scan itself did not run, so "
                                        . "nothing follows about the reception."
             : $scan =~ m/nothing in range/
                                        ? " The board sees no 2.4 GHz network at "
                                        . "all from where it is."
             :                            " The board did not answer the scan.";

    return "credentials stored, but the board could not join the network -- it "
         . "opened the setup access point instead. Check name and password, and "
         . "remember it is 2.4 GHz only.$hint";
}

# Send one line to the bridge console and collect what comes back, up to the
# line that ends the answer or the timeout. Runs inside BlockingCall only --
# it blocks on the serial port.
sub NeatoLocal_ConsoleAsk($$$$) {
    my ($port, $cmd, $stop, $timeout) = @_;

    return "" if (!-e $port || !-w $port);

    system("stty -F " . quotemeta($port) . " 115200 cs8 -cstopb -parenb "
         . "-crtscts -ixon -ixoff raw -echo >/dev/null 2>&1");

    my $fh;
    return "" if (!open($fh, "+<", $port));
    my $old = select($fh); $| = 1; select($old);

    print $fh "\n$cmd\n";

    my $reply = "";
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);
        while (my $line = <$fh>) {
            $reply .= $line;
            last if ($line =~ $stop);
        }
        alarm(0);
    };
    alarm(0);
    close($fh);

    return $reply;
}

sub NeatoLocal_ProvisionWork($) {
    my ($string) = @_;
    my ($name, $port, $ssid, $psk) = split("\\|", $string, 4);

    return "$name|serial port not found: $port" if (!-e $port);
    return "$name|no write access to $port" if (!-w $port);

    # 115200 8N1, no flow control, and no reset of the board on open
    system("stty -F " . quotemeta($port) . " 115200 cs8 -cstopb -parenb "
         . "-crtscts -ixon -ixoff raw -echo >/dev/null 2>&1");

    my $fh;
    return "$name|cannot open $port" if (!open($fh, "+<", $port));

    my $old = select($fh); $| = 1; select($old);

    print $fh "\n";
    print $fh "wifi ssid $ssid\n";
    print $fh "wifi psk $psk\n";
    print $fh "wifi save\n";

    # The board restarts after saving, so the answer we care about comes from
    # the boot after it -- which is also the proof that the credentials were
    # really stored rather than just accepted.
    my $saved = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(10);
        while (my $line = <$fh>) {
            $saved = 1 if ($line =~ m/OK saved/i);
            last if ($saved);
            return "$name|the board rejected the credentials: $line"
                if ($line =~ m/^ERR/i);
        }
        alarm(0);
    };
    alarm(0);
    close($fh);

    return "$name|no answer -- is the board running the bridge firmware?"
        if (!$saved);

    my ($ip, $mode, $reply) = NeatoLocal_AwaitBridge($port);

    return "$name|saved, but the board did not report back after restarting"
        if ($reply eq "");

    # 192.168.4.1 is the setup access point: saved, but not on the network.
    if (!defined($ip) || (defined($mode) && lc($mode) eq "ap")) {
        # Ask the board what it can see. A network missing from that list is
        # either out of reach or 5 GHz only, and neither is a typo in the
        # password -- which is what everybody checks first.
        # The reason code first: it comes straight from the association
        # attempt, while the scan is only circumstantial evidence.
        my $status = NeatoLocal_ConsoleAsk($port, "wifi status", qr/^reason\s/m, 10);
        my $scan   = NeatoLocal_ConsoleAsk($port, "wifi scan",
                                           qr/OK scan done/, 30);
        return "$name|" . NeatoLocal_ScanVerdict($ssid, $scan, $status);
    }

    return "$name|OK|$ip";
}

sub NeatoLocal_ProvisionDone($) {
    my ($string) = @_;
    my ($name, $result, $detail) = split("\\|", $string, 3);
    my $hash = $defs{$name};

    return if (!defined($hash));
    delete $hash->{helper}{flashRunning};
    RemoveInternalTimer($hash, "NeatoLocal_FlashWatch");

    $detail = "" if (!defined($detail));

    if ($result ne "OK") {
        Log3 $name, 1, "NeatoLocal ($name) - provisioning failed: $result $detail";
        readingsSingleUpdate($hash, "lastFlash", "wifi: $result", 1);
        return undef;
    }

    Log3 $name, 3, "NeatoLocal ($name) - bridge reachable at $detail";
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "lastFlash", "wifi ok");
    readingsBulkUpdate($hash, "bridgeAddress", $detail);
    readingsEndUpdate($hash, 1);

    NeatoLocal_AdoptBridgeAddress($hash, $detail);

    return undef;
}

# A device defined without an address was waiting for exactly this. Point it at
# the bridge that just came up, so the whole path from a blank board to a working
# device needs no hand-edited definition.
#
# A device that already has an address keeps it: silently repointing a working
# device would be the wrong kind of helpful.
sub NeatoLocal_AdoptBridgeAddress($$) {
    my ($hash, $ip) = @_;
    my $name = $hash->{NAME};

    return undef if (!defined($ip) || $ip !~ m/^\d+\.\d+\.\d+\.\d+$/);

    if ($hash->{TRANSPORT} eq "none") {
        Log3 $name, 3, "NeatoLocal ($name) - pointing the device at $ip:23";
        my $err = CommandModify(undef, "$name $ip:23");
        if ($err) {
            Log3 $name, 1, "NeatoLocal ($name) - could not set the address: $err";
        }
        else {
            Log3 $name, 2, "NeatoLocal ($name) - address set to $ip:23. "
                         . "Run 'save' to keep it across a restart.";
        }
    }
    else {
        Log3 $name, 3, "NeatoLocal ($name) - the device keeps its address; "
                     . "change it with 'modify $name $ip:23' if wanted";
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

    return "device is disabled"
        if (IsDisabled($name) && $cmd ne "serialPorts");

    my $cl = $hash->{CL};

    # Answered here, not by the robot -- and useful precisely when no device is
    # configured yet.
    if ($cmd eq "serialPorts") {
        return NeatoLocal_FormatSerialPorts(NeatoLocal_ScanSerialPorts());
    }

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
        "accel"      => [ "GetAccel",         \&NeatoLocal_ParseAccel  ],
        "sensors"    => [ "GetAnalogSensors", undef                     ],
        "state"      => [ "GetState",         \&NeatoLocal_ParseState   ],
        "usage"      => [ "GetUsage",         undef                     ],
        "warranty"   => [ "GetWarranty",      \&NeatoLocal_ParseWarranty ],
        "battery"    => [ "GetCharger data",  \&NeatoLocal_ParseBattery  ],
        "settings"   => [ "GetUserSettings",  \&NeatoLocal_ParseUserSettings ],
        "wifiStatus" => [ "GetWifiStatus",    undef                     ],
    );

    my $e = $map{$cmd};
    NeatoLocal_Enqueue($hash, $e->[0], $e->[1], $cl);

    return undef;
}

sub NeatoLocal_LeaveTestMode($) {
    my ($hash) = @_;

    return undef if (!$hash->{helper}{testMode});
    return undef if ($hash->{TRANSPORT} eq "none");
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
    <code>define &lt;name&gt; NeatoLocal [serialDevice|host:port|http://host]</code><br><br>
    Examples:<br>
    <ul>
      <code>define Staubsauger NeatoLocal /dev/ttyACM0@115200</code><br>
      <code>define Staubsauger NeatoLocal 192.168.1.42:23</code><br>
      <code>define Staubsauger NeatoLocal http://neato.local</code><br>
      <code>define Staubsauger NeatoLocal</code> - no bridge yet<br>
    </ul>
    Without an address the device stays in the state <i>unconfigured</i>: it
    does not connect and does not poll, but flashESP and wifiESP work. When
    wifiESP reports the address the bridge came up on, the device points itself
    at it. Follow that with a <code>save</code>.
  </ul><br>

  <a name="NeatoLocalset"></a>
  <b>Set</b>
  <ul>
    <li><b>startCleaning [house|spot|explore|persistent]</b> - starts a cleaning
        run, an exploration run or a run on the stored map <i>explore</i> and <i>persistent</i> are described by the robot's own help as equivalent to starting that run from the Smart App. Observed on a D6 without the cloud: the command is accepted, the robot raises alert 236 UI_ALERT_ACQUIRING_PERSISTENT_MAP_IDS, does not start, and afterwards accepts further cleaning commands without acting on them until it is switched off and on again. Both are therefore refused unless <code>force</code> is appended. <i>house</i> and <i>spot</i> are unaffected.</li>
    <li><b>stop</b> - stops the current run</li>
    <li><b>pause</b> / <b>resume</b> - pauses and resumes a run. Uses the event
        API where available, which keeps map and localization across the pause.
        Without it, both fall back to simulating a press of the Start button,
        which the robot treats as a toggle.</li>
    <li><b>sendToBase</b> - sends the robot home through the event API that the
        app used to drive through the cloud. The documented commands offer no
        way to do this at all.</li>
    <li><b>findMe</b> - plays the "Find me" sound on the robot</li>
    <li><b>clearError</b> - dismisses what the robot reports: GetErr Clear for errors, and SetUIError clearall for alerts, which GetErr Clear leaves standing. An alert the robot keeps raising -- because it is still waiting for something -- comes back regardless.</li>
    <li><b>ecoMode &lt;on|off&gt;</b>, <b>intenseClean &lt;on|off&gt;</b>,
        <b>binFullDetect &lt;on|off&gt;</b> - user settings on the robot. Unlike
        the navigation mode these are read back afterwards, so their readings
        come from the device.</li>
    <li><b>navigationMode &lt;Normal|Gentle|Deep|Quick&gt;</b> - cleaning mode.
        The console has no command to read it back, so the reading of the same
        name is what FHEM last set, not what the robot reports. It is re-sent
        before every house cleaning, because the robot does not keep the mode
        across runs.</li>
    <li><b>syncTime</b> - sets the robot's scheduler clock from FHEM. Without
        the cloud nothing else keeps that clock right.</li>
    <li><b>button &lt;name&gt;</b> - simulates any UI or IR button press</li>
    <li><b>buildPlan</b> - computes one floor plan from the last recordings and
        writes it as plan-&lt;device&gt;.json beside them. Runs in a forked,
        niced process and takes minutes; the reading <b>planFile</b> names the
        result. Needs recordings with lidar scans, so trackRuns and
        mapInterval have to be set.<br>
        <b>planState</b> carries the grade of every run that was left out, for
        instance "ok, 1 did not fit (0.33)". The threshold a run is measured
        against is an assumption and not a measurement, so it is worth logging
        this reading: over a few weeks it is the series that says whether the
        threshold sits in the right place. The file itself carries the grades
        of all runs in its "scores" field.</li>
    <li><b>statusRequest</b> - polls charger, error and motor state</li>
    <li><b>testMode &lt;on|off&gt;</b> - enters/leaves the console test mode.
        <b>While test mode is on the robot ignores its own buttons and will
        not clean.</b> The module always sends "TestMode Off" on shutdown,
        delete and disable.</li>
    <li><b>flashESP [&lt;image|url&gt;] [&lt;ssid&gt; &lt;password&gt;]</b> -
        writes the bridge firmware to a board on the FHEM machine's USB port,
        using esptool. Without an image the one this project builds is fetched.
        Anything that is not a firmware image is refused before the board is
        touched. Given a network, the credentials are written to their own
        partition in a second pass and taken into NVS on the first boot, so no
        console dialogue and no software restart are needed. The bridge is
        powered by the robot, so this is for a board that is not installed yet.
        Quote values containing spaces:
        <code>set &lt;dev&gt; flashESP "My WLAN" "secret phrase"</code></li>
    <li><b>wifiESP &lt;ssid&gt; &lt;password&gt;</b> - hands the credentials to an
        already flashed board over its USB port and reports the address it
        ends up with in the reading bridgeAddress. For a board that is being
        flashed anyway, flashESP does this in the same pass.</li>
    <li><b>otaESP [&lt;ip&gt;] [&lt;image|url&gt;]</b> - updates an installed
        bridge over the air, which is the only way once it is built into the
        robot. Without an image the application this project publishes is
        fetched -- the one without bootloader and partition table, because an
        update is written into an app partition. The address is taken from the
        device unless one is given. Every version of the bridge supports this,
        so a board flashed long before this command existed can still be
        updated. Firmware before 0.4.0 is the exception: it holds the network
        inside its image, so an update takes the credentials with it and the
        bridge comes up as the access point 'neato-setup', to be given a network
        again at http://192.168.4.1/. Such an update is refused until
        <code>set &lt;dev&gt; otaESP force</code>.</li>
    <li><b>raw &lt;command&gt;</b> - sends an arbitrary console command</li>
    <li><b>reconnect</b> - reopens the connection</li>
  </ul><br>

  <a name="NeatoLocalget"></a>
  <b>Get</b>
  <ul>
    <li><b>help [command]</b> - returns the robot's own command list. Use this
        to verify the console syntax of your firmware.</li>
    <li><b>raw &lt;command&gt;</b> - sends a command and returns its output</li>
    <li><b>accel</b> - the angle the robot stands at, as the readings pitch,
        roll and accelSum. The sensor carries no calibration: a D6 level on its
        base reports -2.33 / -1.20 degrees at 0.951 g, so the numbers are good
        for a change and not for an absolute angle. While a run records scans,
        the same reading is taken just before each one and written into the
        session file as "tilt". The idea was that a scan taken askew has the
        floor in it shaped exactly like a wall, which within one revolution
        cannot be told apart. Measured over a full run it explains nothing --
        the correlation with stray points is +0.05 -- so there is deliberately
        no filter on it. See docs/ftui3-map.md, and tools/stray_points.py to
        redo the measurement on a newer recording.</li>
    <li><b>serialPorts</b> - lists the serial ports the machine has, with their
        stable by-id names and a guess at what is behind each. Answered locally,
        so it works before any bridge exists.</li>
    <li><b>version</b>, <b>state</b>, <b>charger</b>, <b>battery</b>,
        <b>motors</b>, <b>sensors</b>, <b>usage</b>, <b>warranty</b>,
        <b>settings</b>, <b>wifiStatus</b></li>
  </ul><br>

  <a name="NeatoLocalattr"></a>
  <b>Attributes</b>
  <ul>
    <li><b>interval</b> - polling interval in seconds, default 60</li>
    <li><b>timeout</b> - response timeout in seconds, default 10</li>
    <li><b>espPort</b> - the USB port the bridge board is on while it is being
        flashed, default /dev/ttyACM0</li>
    <li><b>espImage</b> - image flashESP writes instead of the one this project publishes</li>
    <li><b>espAppImage</b> - application otaESP sends instead of the published one</li>
    <li><b>trackRuns</b> - record the driven track while the robot cleans. Off by
        default: it writes a file per run, which is of no use to anyone who does
        not draw it somewhere</li>
    <li><b>trackDir</b> - where the session files go, default ./www/neato</li>
    <li><b>trackInterval</b> - seconds between pose samples, default 3</li>
    <li><b>trackPose</b> - which pose the track is built from: Smooth (the
        default, the robot's corrected position) or Raw (the wheel encoders on
        their own, which drift over a run)</li>
    <li><b>mapInterval</b> - seconds between lidar scans during a run, 0 (the
        default) records the track only. A scan is 360 rows and occupies the
        console for about half a second, so it goes on its own schedule</li>
    <li><b>mapMaxRange</b> - millimetres past which a reading is not a
        measurement, default 6000. Needed on top of the error code: real scans
        contain readings around 16.8 m with a clean error code, where nothing
        returned the beam</li>
    <li><b>trackKeepDays</b> - how long finished sessions are kept, default 14.
        Swept after each run; 0 keeps them for good. Only files this device
        wrote itself are ever removed</li>
    <li><b>planAuto</b> - compute the floor plan after every cleaning run,
        default 0. A run without scans is skipped; there is nothing to build a
        plan from.</li>
    <li><b>planSources</b> - how many recordings go into the plan, newest
        first, default 8. Every one of them costs about a minute, and runs
        from the same afternoon see the same furniture in the same place and
        agree for the wrong reason.</li>
    <li><b>planCell</b> - the cell size of the plan in metres, default 0.10.
        It is written into the file, so the display uses whatever is set
        here.</li>
    <li><b>connectTimeout</b> - how long a connection attempt to the bridge may
        take, default 2 seconds. FHEM opens TCP connections synchronously, so
        this is the longest FHEM can stall while the bridge is unreachable --
        which it is whenever the robot is off, since it powers the bridge.</li>
    <li><b>pollErrors</b> - poll GetErr, default 1</li>
    <li><b>pollSettings</b> - also poll GetUserSettings every cycle, default 0.
        They are read on connect and after every change anyway.</li>
    <li><b>pollState</b> - poll GetState, default 1. This is what the robot
        itself reports and is far more reliable than inferring the state.</li>
    <li><b>pollMotors</b> - poll GetMotors, default 0 since GetState replaced
        its role</li>
    <li><b>useSetEvent</b> - use the event API where available, default 1.
        Setting this to 0 forces the documented commands.</li>
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
    <li><b>ecoMode</b>, <b>intenseClean</b>, <b>binFullDetect</b>,
        <b>wallFollower</b>, <b>clickSounds</b>, <b>melodySounds</b>,
        <b>warningSounds</b>, <b>led</b>, <b>wifiEnabled</b>, <b>language</b>,
        <b>filterChangeTime</b>, <b>brushChangeTime</b>, <b>dirtBinInterval</b>,
        <b>scheduleEnabled</b>, <b>scheduledCleanings</b> - from
        GetUserSettings, fetched on connect and after every change</li>
    <li><b>batteryHealth</b> - the pack's remaining capacity as a percentage of
        its design capacity, from the smart battery's own gauge. Below roughly
        50% a robot starts failing to make it back to the base.</li>
    <li><b>batteryCapacityFull</b>, <b>batteryCapacityDesign</b>,
        <b>batteryTemperature</b>, <b>batteryCycles</b>, <b>cleaningHours</b> -
        the rest of the battery and lifetime figures</li>
    <li><b>uiState</b>, <b>robotState</b> - what the robot reports about
        itself, e.g. UIMGR_STATE_STANDBY and ST_C_Standby</li>
    <li><b>commandApi</b> - setEvent or legacy, depending on whether the event
        API could be unlocked</li>
    <li><b>state</b> - cleaning, paused, suspended, docking, charging, docked,
        idle, error, robotSilent, unreachable or
        disconnected. <i>suspended</i> means the robot interrupted the run by
        itself, usually to charge, and intends to resume.
        <i>robotSilent</i> means the connection to the bridge is up but the
        robot does not answer -- asleep, or a bridge not wired to it yet, which
        is simply what a freshly flashed board looks like.
        <i>unreachable</i> means the connection itself is gone: the bridge is
        off the network, or without power. In both cases polling backs off up
        to 16x the interval instead of filling the log.</li>
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
    <code>define &lt;name&gt; NeatoLocal [serielles Geraet|host:port|http://host]</code><br><br>
    Beispiele:<br>
    <ul>
      <code>define Staubsauger NeatoLocal /dev/ttyACM0@115200</code><br>
      <code>define Staubsauger NeatoLocal 192.168.1.42:23</code><br>
      <code>define Staubsauger NeatoLocal http://neato.local</code><br>
      <code>define Staubsauger NeatoLocal</code> - noch keine Bruecke<br>
    </ul>
    Ohne Adresse bleibt das Geraet im Zustand <i>unconfigured</i>: es verbindet
    sich nicht und fragt nichts ab, flashESP und wifiESP funktionieren aber.
    Sobald wifiESP die Adresse meldet, unter der die Bruecke hochgekommen ist,
    stellt sich das Geraet selbst darauf um. Danach ein <code>save</code>.
  </ul><br>

  <a name="NeatoLocalset"></a>
  <b>Set</b>
  <ul>
    <li><b>startCleaning [house|spot|explore|persistent]</b> - startet eine
        Reinigung, eine Erkundungsfahrt oder eine Fahrt auf der gespeicherten
        Karte <i>explore</i> und <i>persistent</i> beschreibt die Hilfe des Roboters selbst als Entsprechung zum Start aus der Smart App. Beobachtet an einem D6 ohne Cloud: das Kommando wird angenommen, der Roboter setzt Alarm 236 UI_ALERT_ACQUIRING_PERSISTENT_MAP_IDS, faehrt nicht los und nimmt danach weitere Reinigungsbefehle an, ohne etwas zu tun -- bis er aus- und wieder eingeschaltet wird. Beide werden deshalb abgelehnt, solange nicht <code>force</code> angehaengt wird. <i>house</i> und <i>spot</i> sind davon nicht betroffen.</li>
    <li><b>stop</b> - beendet die laufende Reinigung</li>
    <li><b>pause</b> / <b>resume</b> - pausiert und setzt fort. Nutzt die
        Event-Schnittstelle, wenn verfuegbar; damit bleiben Karte und
        Selbstlokalisierung ueber die Pause erhalten. Ohne sie simulieren beide
        einen Druck auf die Start-Taste, den der Roboter als Umschalter
        behandelt.</li>
    <li><b>sendToBase</b> - schickt den Roboter zur Basis, ueber die
        Event-Schnittstelle, mit der die App das durch die Cloud getan hat. Mit
        den dokumentierten Kommandos ist das gar nicht moeglich.</li>
    <li><b>findMe</b> - spielt den Ton "Find me" ab</li>
    <li><b>clearError</b> - quittiert, was der Roboter meldet: GetErr Clear fuer Fehler und SetUIError clearall fuer Alarme, die GetErr Clear stehen laesst. Ein Alarm, den der Roboter immer wieder setzt -- weil er weiter auf etwas wartet -- kommt trotzdem zurueck.</li>
    <li><b>ecoMode &lt;on|off&gt;</b>, <b>intenseClean &lt;on|off&gt;</b>,
        <b>binFullDetect &lt;on|off&gt;</b> - Einstellungen im Roboter. Anders
        als der Navigationsmodus werden sie danach zurueckgelesen, die Readings
        stammen also vom Geraet.</li>
    <li><b>navigationMode &lt;Normal|Gentle|Deep|Quick&gt;</b> - Reinigungsmodus.
        Die Konsole kennt kein Kommando, ihn auszulesen; das gleichnamige
        Reading ist deshalb das, was FHEM zuletzt gesetzt hat, nicht die
        Auskunft des Roboters. Es wird vor jeder Hausreinigung erneut gesendet,
        weil der Roboter den Modus nicht ueber Laeufe hinweg behaelt.</li>
    <li><b>syncTime</b> - stellt die Uhr des Zeitgebers aus FHEM. Ohne Cloud
        haelt sonst nichts mehr diese Uhr richtig.</li>
    <li><b>button &lt;name&gt;</b> - simuliert einen beliebigen Tastendruck</li>
    <li><b>buildPlan</b> - rechnet aus den letzten Aufzeichnungen einen
        gemeinsamen Grundriss und legt ihn als plan-&lt;Geraet&gt;.json daneben.
        Laeuft in einem eigenen, heruntergestuften Prozess und dauert Minuten;
        das Reading <b>planFile</b> nennt das Ergebnis. Braucht Aufzeichnungen
        mit Lidar-Scans, also trackRuns und mapInterval.<br>
        <b>planState</b> nennt die Guete jedes ausgelassenen Laufs, etwa
        "ok, 1 did not fit (0.33)". Die Schwelle, an der gemessen wird, ist
        eine Annahme und keine Messung -- dieses Reading mitzuloggen lohnt sich
        also: ueber ein paar Wochen ist es die Reihe, die sagt, ob die Schwelle
        richtig liegt. Die Datei selbst traegt die Guete aller Laeufe im Feld
        "scores".</li>
    <li><b>statusRequest</b> - fragt Ladezustand, Fehler und Motoren ab</li>
    <li><b>testMode &lt;on|off&gt;</b> - schaltet den Testmodus der Konsole.
        <b>Im Testmodus reagiert der Roboter nicht mehr auf seine Tasten und
        reinigt nicht.</b> Das Modul sendet bei Shutdown, Loeschen und
        Deaktivieren immer "TestMode Off".</li>
    <li><b>flashESP [&lt;Image|URL&gt;] [&lt;SSID&gt; &lt;Passwort&gt;]</b> -
        schreibt die Bruecken-Firmware auf ein Board am USB-Port des
        FHEM-Rechners, per esptool. Ohne Angabe wird das Image geholt, das
        dieses Projekt baut. Was keine Firmware ist, wird abgelehnt, bevor das
        Board angefasst wird. Mit einem Netz werden die Zugangsdaten in einem
        zweiten Schreibvorgang in eine eigene Partition gelegt und beim ersten
        Start ins NVS uebernommen -- ohne Konsolendialog und ohne
        Software-Neustart. Die Bruecke wird vom Roboter versorgt, das ist also
        fuer ein noch nicht eingebautes Board. Werte mit Leerzeichen gehoeren in
        Anfuehrungszeichen:
        <code>set &lt;dev&gt; flashESP "Mein WLAN" "lange Passphrase"</code></li>
    <li><b>wifiESP &lt;SSID&gt; &lt;Passwort&gt;</b> - uebergibt einem bereits
        geflashten Board die Zugangsdaten ueber dessen USB-Port und meldet die
        Adresse, unter der es erreichbar wird, im Reading bridgeAddress. Wird
        ohnehin geflasht, erledigt flashESP das in einem Zug.</li>
    <li><b>otaESP [&lt;IP&gt;] [&lt;Image|URL&gt;]</b> - aktualisiert eine
        verbaute Bruecke ueber Funk, was der einzige Weg ist, sobald sie im
        Roboter steckt. Ohne Angabe wird die Anwendung geholt, die dieses
        Projekt veroeffentlicht -- die ohne Bootloader und Partitionstabelle,
        denn ein Update landet in einer App-Partition. Die Adresse nimmt der
        Befehl vom Geraet, wenn keine angegeben ist. Jede Version der Bruecke
        kann das, ein lange vorher geflashtes Board also auch. Ausnahme ist
        Firmware vor 0.4.0: sie haelt das Netz im Image, ein Update nimmt die
        Zugangsdaten also mit, und die Bruecke kommt als Access Point
        'neato-setup' hoch, wo sie unter http://192.168.4.1/ ein neues Netz
        bekommt. Ein solches Update wird abgelehnt, bis man
        <code>set &lt;dev&gt; otaESP force</code> sagt.</li>
    <li><b>raw &lt;Kommando&gt;</b> - sendet ein beliebiges Konsolenkommando</li>
    <li><b>reconnect</b> - baut die Verbindung neu auf</li>
  </ul><br>

  <a name="NeatoLocalget"></a>
  <b>Get</b>
  <ul>
    <li><b>help [Kommando]</b> - liefert die Kommandoliste des Roboters. Damit
        laesst sich die Syntax der eigenen Firmware pruefen.</li>
    <li><b>raw &lt;Kommando&gt;</b> - sendet ein Kommando und gibt die Ausgabe zurueck</li>
    <li><b>accel</b> - die Neigung des Roboters, als Readings pitch, roll und
        accelSum. Der Sensor ist nicht kalibriert: ein D6, der waagerecht auf
        der Basis steht, meldet -2,33 / -1,20 Grad bei 0,951 g. Die Werte taugen
        also fuer eine Aenderung, nicht fuer einen absoluten Winkel. Waehrend
        eines Laufs mit Scans wird derselbe Wert unmittelbar vor jedem Scan
        genommen und als "tilt" in die Sitzungsdatei geschrieben. Der Gedanke
        war, dass ein schraeg aufgenommener Scan den Fussboden in der Form einer
        Wand enthaelt, die innerhalb einer Umdrehung nicht zu unterscheiden ist.
        An einem vollen Lauf gemessen erklaert das nichts -- die Korrelation mit
        verirrten Punkten liegt bei +0,05 --, es gibt deshalb bewusst keinen
        Filter darauf. Siehe docs/ftui3-map.md, und tools/stray_points.py, um
        die Messung auf einer neueren Aufzeichnung zu wiederholen.</li>
    <li><b>serialPorts</b> - listet die seriellen Schnittstellen des Rechners
        mit ihren gleichbleibenden by-id-Namen und einer Vermutung, was
        dahintersteckt. Wird lokal beantwortet und funktioniert daher auch,
        bevor es eine Bruecke gibt.</li>
    <li><b>version</b>, <b>state</b>, <b>charger</b>, <b>battery</b>,
        <b>motors</b>, <b>sensors</b>, <b>usage</b>, <b>warranty</b>,
        <b>settings</b>, <b>wifiStatus</b></li>
  </ul><br>

  <a name="NeatoLocalattr"></a>
  <b>Attribute</b>
  <ul>
    <li><b>interval</b> - Abfrageintervall in Sekunden, Standard 60</li>
    <li><b>timeout</b> - Antwort-Timeout in Sekunden, Standard 10</li>
    <li><b>espPort</b> - der USB-Port, an dem das Bruecken-Board beim Flashen
        haengt, Standard /dev/ttyACM0</li>
    <li><b>espImage</b> - Image, das flashESP statt des von diesem Projekt veroeffentlichten schreibt</li>
    <li><b>espAppImage</b> - Anwendung, die otaESP statt der veroeffentlichten sendet</li>
    <li><b>trackRuns</b> - zeichnet die gefahrene Spur waehrend der Reinigung auf.
        Standardmaessig aus: es entsteht eine Datei je Lauf, und die nuetzt
        niemandem, der sie nirgends darstellt</li>
    <li><b>trackDir</b> - wohin die Sitzungsdateien gehen, Standard ./www/neato</li>
    <li><b>trackInterval</b> - Sekunden zwischen zwei Positionsabfragen, Standard 3</li>
    <li><b>trackPose</b> - aus welcher Position die Spur entsteht: Smooth
        (Standard, die korrigierte Position des Roboters) oder Raw (die
        Radencoder allein, die ueber einen Lauf driften)</li>
    <li><b>mapInterval</b> - Sekunden zwischen zwei Lidar-Scans waehrend eines
        Laufs, 0 (Standard) zeichnet nur die Spur auf. Ein Scan sind 360 Zeilen
        und belegt die Konsole etwa eine halbe Sekunde, er laeuft daher nach
        eigenem Takt</li>
    <li><b>mapMaxRange</b> - ab wie vielen Millimetern ein Wert keine Messung
        mehr ist, Standard 6000. Zusaetzlich zum Fehlercode noetig: echte Scans
        enthalten Werte um 16,8 m mit Fehlercode 0, dort wo nichts
        zurueckgestrahlt hat</li>
    <li><b>trackKeepDays</b> - wie lange fertige Sitzungen bleiben, Standard 14.
        Aufgeraeumt wird nach jedem Lauf; 0 behaelt alles. Entfernt werden nur
        Dateien, die dieses Geraet selbst geschrieben hat</li>
    <li><b>planAuto</b> - nach jeder Reinigung den Grundriss neu rechnen,
        Standard 0. Ein Lauf ohne Scans wird uebersprungen, aus ihm entsteht
        kein Grundriss.</li>
    <li><b>planSources</b> - wie viele Aufzeichnungen in den Grundriss eingehen,
        die neuesten zuerst, Standard 8. Jede kostet etwa eine Minute, und zwei
        Laeufe vom selben Nachmittag sehen dieselben Moebel am selben Platz und
        sind sich aus dem falschen Grund einig.</li>
    <li><b>planCell</b> - die Zellgroesse des Grundrisses in Metern, Standard
        0,10. Sie steht in der Datei, die Anzeige uebernimmt also, was hier
        eingestellt ist.</li>
    <li><b>connectTimeout</b> - wie lange ein Verbindungsversuch zur Bruecke
        dauern darf, Standard 2 Sekunden. FHEM baut TCP-Verbindungen synchron
        auf; das ist also die laengste Zeit, die FHEM stehenbleiben kann,
        solange die Bruecke nicht erreichbar ist - und das ist sie immer dann
        nicht, wenn der Roboter aus ist, denn er versorgt sie.</li>
    <li><b>pollErrors</b> - GetErr mit abfragen, Standard 1</li>
    <li><b>pollSettings</b> - GetUserSettings bei jedem Durchlauf mitfragen,
        Standard 0. Beim Verbinden und nach jeder Aenderung werden sie ohnehin
        gelesen.</li>
    <li><b>pollState</b> - GetState abfragen, Standard 1. Das ist der Zustand,
        den der Roboter selbst meldet, und damit deutlich verlaesslicher als
        jede Ableitung.</li>
    <li><b>pollMotors</b> - GetMotors abfragen, Standard 0, seit GetState diese
        Aufgabe uebernommen hat</li>
    <li><b>useSetEvent</b> - die Event-Schnittstelle nutzen, wenn verfuegbar,
        Standard 1. Mit 0 werden die dokumentierten Kommandos erzwungen.</li>
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
    <li><b>ecoMode</b>, <b>intenseClean</b>, <b>binFullDetect</b>,
        <b>wallFollower</b>, <b>clickSounds</b>, <b>melodySounds</b>,
        <b>warningSounds</b>, <b>led</b>, <b>wifiEnabled</b>, <b>language</b>,
        <b>filterChangeTime</b>, <b>brushChangeTime</b>, <b>dirtBinInterval</b>,
        <b>scheduleEnabled</b>, <b>scheduledCleanings</b> - aus
        GetUserSettings, beim Verbinden und nach jeder Aenderung geholt</li>
    <li><b>batteryHealth</b> - Restkapazitaet des Akkus in Prozent seiner
        Nennkapazitaet, aus der Messelektronik des Akkus selbst. Unterhalb von
        etwa 50 Prozent schafft es ein Roboter zunehmend nicht mehr zurueck zur
        Basis.</li>
    <li><b>batteryCapacityFull</b>, <b>batteryCapacityDesign</b>,
        <b>batteryTemperature</b>, <b>batteryCycles</b>, <b>cleaningHours</b> -
        die uebrigen Akku- und Lebensdauerwerte</li>
    <li><b>uiState</b>, <b>robotState</b> - was der Roboter ueber sich selbst
        meldet, z. B. UIMGR_STATE_STANDBY und ST_C_Standby</li>
    <li><b>commandApi</b> - setEvent oder legacy, je nachdem ob sich die
        Event-Schnittstelle freischalten liess</li>
    <li><b>state</b> - cleaning, paused, suspended, docking, charging, docked,
        idle, error, robotSilent, unreachable oder disconnected.
        <i>suspended</i> heisst: der Roboter hat die Reinigung selbst
        unterbrochen, meist wegen leerem Akku, und will sie nach dem Laden
        fortsetzen. <i>robotSilent</i> heisst: die Verbindung zur Bruecke steht,
        aber der Roboter antwortet nicht -- er schlaeft, oder die Bruecke ist
        noch nicht mit ihm verdrahtet; nach dem Flashen ist genau das der
        normale Zustand. <i>unreachable</i> heisst: die Verbindung selbst ist
        weg, die Bruecke also nicht im Netz oder ohne Strom. In beiden Faellen
        geht die Abfrage bis auf das 16-fache Intervall zurueck, statt das Log
        zu fluten.</li>
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
