/*
 * neato_bridge -- transparent WiFi-to-serial bridge for Neato Botvac robots.
 *
 * Bridges a TCP connection to the robot's serial console, which is exactly what
 * 74_NeatoLocal.pm expects on its TCP transport:
 *
 *     define Staubsauger NeatoLocal <ip-of-this-board>:23
 *
 * Target: ESP32-C3, e.g. a "Super Mini" -- fqbn esp32:esp32:esp32c3
 *
 * The bridge stays deliberately dumb: it does not parse, buffer by command or
 * rewrite anything, so the FHEM module keeps full control of the console. Two
 * exceptions earn their place:
 *
 *   - when a client disconnects, "TestMode Off" is sent to the robot, because a
 *     robot left in test mode ignores its own buttons and refuses to clean;
 *   - a small status page on port 80, because once this board is glued inside
 *     the robot there is no other way to see whether it is alive.
 *
 * WIRING -- the robot's debug header is RX | 3.3V | TX | GND (left to right).
 * TX and RX are crossed:
 *
 *   Robot TX -> GPIO4 (RX),  Robot RX <- GPIO5 (TX)
 *   GND -- GND,  robot 3.3V -> the board's 3V3 pin
 *
 * Never feed the board from USB and the robot at the same time: flash over USB
 * with the robot disconnected, unplug USB, then connect the robot. A 220 uF
 * electrolytic plus 100 nF across 3V3/GND at the module absorbs the WiFi
 * transmit peaks.
 *
 * A dedicated UART (Serial1) talks to the robot while the USB CDC port stays
 * free, so the serial monitor keeps working for good -- that is what makes the
 * C3 the right target here, and the reason this sketch no longer carries the
 * ESP8266, which has only one usable UART and loses its console to the robot.
 * Watch the monitor at 115200 baud.
 *
 * Part of https://github.com/chrisse1/neato-FHEM
 */

#if !defined(ARDUINO_ARCH_ESP32)
  #error "neato_bridge targets the ESP32-C3"
#endif

#include <WiFi.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include <Preferences.h>
#include <esp_wifi.h>         // esp_wifi_set_country_code()
#include <esp_system.h>       // esp_reset_reason()
#include <esp_partition.h>    // the credentials block written at flash time

#define ROBOT Serial1         // dedicated UART, the USB CDC port stays free

// ---------------------------------------------------------------- config ---

#ifndef WIFI_SSID
#define WIFI_SSID "your-ssid"
#endif
#ifndef WIFI_PSK
#define WIFI_PSK "your-password"
#endif

// Channels 12 and 13 are allowed in Europe and routers do pick them, but a
// board still carrying the factory "world safe" setting leaves them out of
// every scan -- a network up there is then simply not there as far as the
// board is concerned. Override for another region at compile time.
#ifndef WIFI_COUNTRY
#define WIFI_COUNTRY "DE"
#endif

// ESP32 only: the pins the robot's debug header is wired to. GPIO4/GPIO5 are
// free on the C3 Super Mini and, unlike GPIO20/GPIO21, never collide with the
// board's own console.
#ifndef ROBOT_RX_PIN
#define ROBOT_RX_PIN 4
#endif
#ifndef ROBOT_TX_PIN
#define ROBOT_TX_PIN 5
#endif

static const char *VERSION = "0.14.0";
static const char *HOSTNAME = "neato";     // reachable as neato.local
static const uint16_t TCP_PORT = 23;       // must match the FHEM define
static const uint16_t HTTP_PORT = 80;      // status page
static const uint32_t ROBOT_BAUD = 115200; // the console speaks 115200 8N1

// Drop a client that has been silent for this long, so a crashed FHEM does not
// block the single connection slot forever. 0 disables the timeout.
static const uint32_t IDLE_TIMEOUT_MS = 15UL * 60UL * 1000UL;

// ------------------------------------------------------------------ state --

static WiFiServer bridgeServer(TCP_PORT);
static WiFiServer httpServer(HTTP_PORT);
static WiFiClient client;

static uint32_t lastClientActivity = 0;
static uint32_t bytesToRobot = 0;
static uint32_t bytesFromRobot = 0;
static uint32_t lastRobotByte = 0;     // millis() of the last byte the robot sent
static uint32_t clientCount = 0;
static uint32_t linkDrops = 0;         // how often the link was found down

// The credentials the board is actually using. They live in NVS, so one prebuilt
// image fits every network; the #defines above are only a fallback for a
// self-compiled binary.
static String wifiSsid;
static String wifiPsk;
static bool apMode = false;     // no credentials: running as an access point

// Why the station side last dropped or refused to associate. This is the one
// number that separates "wrong password" from "network not found" -- from the
// outside both look like a board that simply does not turn up.
static volatile int lastDisconnectReason = 0;
// Taking the station side down for a scan raises a disconnect event too. That
// one says something about this sketch, not about the router, so it must not
// overwrite the reason the diagnosis rests on.
static volatile bool ignoreDisconnects = false;

static Preferences prefs;

// What a freshly flashed image carries when nobody filled the defines in.
static bool isPlaceholder(const String &ssid) {
  return ssid.length() == 0 || ssid == "your-ssid";
}

// A freshly flashed board can be handed its network in the same pass: the
// flashing tool writes a small block into the storage partition, and the first
// boot takes it into NVS and wipes it again. That removes the console dialogue
// and with it the software restart the dialogue needed -- the board comes up
// out of a real reset already knowing where to connect.
//
// The block is deliberately not checksummed. The magic word plus the length
// bounds already rule out erased flash and a short write, and two independent
// checksum implementations that must agree byte for byte would be a worse risk
// than the one they cover.
#define SEED_MAGIC     "NEATOSEED1"
#define SEED_MAGIC_LEN 10
#define SEED_SSID_MAX  32
#define SEED_PSK_MAX   64
#define SEED_SIZE      128

static bool seedUsed = false;      // for the boot log: where the network came from

// The stock partition schemes do not agree on a name for the storage partition,
// so the candidates are listed rather than guessed at -- the same list the
// flashing side uses to find the offset.
static const char *seedLabels[] = { "spiffs", "storage", "littlefs", "ffat" };

static const esp_partition_t *seedPartition() {
  for (size_t i = 0; i < sizeof(seedLabels) / sizeof(seedLabels[0]); i++) {
    const esp_partition_t *part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, seedLabels[i]);
    if (part != NULL) {
      return part;
    }
  }
  return NULL;
}

static bool configSeedTake(String &ssid, String &psk) {
  const esp_partition_t *part = seedPartition();
  if (part == NULL) {
    return false;
  }

  uint8_t buf[SEED_SIZE];
  if (esp_partition_read(part, 0, buf, sizeof(buf)) != ESP_OK) {
    return false;
  }
  if (memcmp(buf, SEED_MAGIC, SEED_MAGIC_LEN) != 0) {
    return false;
  }

  uint8_t ssidLen = buf[SEED_MAGIC_LEN];
  uint8_t pskLen  = buf[SEED_MAGIC_LEN + 1];
  if (ssidLen == 0 || ssidLen > SEED_SSID_MAX || pskLen > SEED_PSK_MAX) {
    return false;
  }

  char ssidBuf[SEED_SSID_MAX + 1];
  char pskBuf[SEED_PSK_MAX + 1];
  memcpy(ssidBuf, buf + SEED_MAGIC_LEN + 2, ssidLen);
  ssidBuf[ssidLen] = '\0';
  memcpy(pskBuf, buf + SEED_MAGIC_LEN + 2 + SEED_SSID_MAX, pskLen);
  pskBuf[pskLen] = '\0';

  ssid = String(ssidBuf);
  psk = String(pskBuf);

  // One shot: wiped so that a later change over the console is not overruled on
  // the next boot, and so the password does not sit in flash beyond the moment
  // it is needed.
  esp_partition_erase_range(part, 0, 4096);
  return true;
}

static void configLoad() {
  // Whatever the flashing tool left behind wins: it is newer than anything in
  // NVS by definition, and it is gone after this.
  String seedSsid, seedPsk;
  if (configSeedTake(seedSsid, seedPsk)) {
    prefs.begin("neato", false);
    prefs.putString("ssid", seedSsid);
    prefs.putString("psk", seedPsk);
    prefs.end();
    seedUsed = true;
  }

  prefs.begin("neato", true);
  wifiSsid = prefs.getString("ssid", "");
  wifiPsk = prefs.getString("psk", "");
  prefs.end();
  if (isPlaceholder(wifiSsid)) {
    wifiSsid = WIFI_SSID;
    wifiPsk = WIFI_PSK;
  }
  if (isPlaceholder(wifiSsid)) {
    wifiSsid = "";
    wifiPsk = "";
  }
}

static bool configSave(const String &ssid, const String &psk) {
  if (ssid.length() == 0 || ssid.length() > 32 || psk.length() > 63) {
    return false;
  }
  prefs.begin("neato", false);
  prefs.putString("ssid", ssid);
  prefs.putString("psk", psk);
  prefs.end();
  wifiSsid = ssid;
  wifiPsk = psk;
  return true;
}

// Read the credentials straight back out of the store. Saving reports success
// even when the partition is full or missing, and a board that silently keeps
// nothing looks exactly like a wrong password after the next restart.
static bool configVerify(const String &ssid, const String &psk) {
  prefs.begin("neato", true);
  String storedSsid = prefs.getString("ssid", "");
  String storedPsk = prefs.getString("psk", "");
  prefs.end();
  return storedSsid == ssid && storedPsk == psk;
}

static void configClear() {
  prefs.begin("neato", false);
  prefs.clear();
  prefs.end();
}

// --------------------------------------------------------------- helpers ---

static void dbg(const String &line) {
  Serial.println(line);
}

// Accept a pending connection. The spelling changed across core versions.
static WiFiClient acceptFrom(WiFiServer &server) {
  return server.accept();
}

// Leave the robot in a usable state: in test mode it ignores its buttons and
// will not clean, so we never let a disconnect strand it there.
static void leaveTestMode() {
  ROBOT.print(F("TestMode Off\n"));
  ROBOT.flush();
}

static void dropClient() {
  if (!client) {
    return;
  }
  leaveTestMode();
  client.stop();
}

static void setupRobotSerial() {
  Serial.begin(115200);          // USB CDC, stays available
  Serial1.setRxBufferSize(1024);
  Serial1.begin(ROBOT_BAUD, SERIAL_8N1, ROBOT_RX_PIN, ROBOT_TX_PIN);
}

// The disconnect codes worth naming. Anything unlisted is printed as a bare
// number rather than guessed at.
static const __FlashStringHelper *disconnectReasonText(int reason) {
  switch (reason) {
    case 2:   return F("authentication expired");
    case 4:   return F("association expired");
    case 15:  return F("password refused (4-way handshake timed out)");
    case 200: return F("beacon lost");
    case 201: return F("network not found");
    case 202: return F("authentication refused");
    case 203: return F("association refused");
    case 204: return F("handshake timed out");
    case 205: return F("connection failed");
    default:  return NULL;    // printed as a bare number rather than guessed at
  }
}

static void printDisconnectReason() {
  Serial.print(F("reason "));
  Serial.print(lastDisconnectReason);
  // NULL for an unknown code rather than an empty F(""), which would have to be
  // inspected to tell it apart -- and a flash string is not for poking at.
  const __FlashStringHelper *text = disconnectReasonText(lastDisconnectReason);
  if (text != NULL) {
    Serial.print(' ');
    Serial.print(text);
  }
  Serial.println();
}

// Registered once, before the first connect attempt, so nothing is missed.
static void watchDisconnects() {
  WiFi.onEvent([](WiFiEvent_t event, WiFiEventInfo_t info) {
    if (!ignoreDisconnects) {
      lastDisconnectReason = (int)info.wifi_sta_disconnected.reason;
    }
  }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
}

// Must be applied after the radio is up, i.e. after WiFi.mode(), and again
// whenever the mode changes.
static void applyRegulatoryDomain() {
  // true: follow the access point's own country information once associated.
  esp_wifi_set_country_code(WIFI_COUNTRY, true);
}

// What the board can actually see. A network that only exists on 5 GHz, and a
// board whose antenna barely reaches the router, both look exactly like a
// wrong password from the outside -- the scan tells them apart.
//
// Why the board started. "Was it up at all?" is the first question when
// something is reachable and then is not, and a reset triggered from the USB
// host looks nothing like a brownout or a crash -- but all three end with a
// board that went away for a moment.
static String bootReason() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON:   return F("power on");
    case ESP_RST_EXT:       return F("external reset");
    case ESP_RST_SW:        return F("software restart");
    case ESP_RST_PANIC:     return F("crash");
    case ESP_RST_INT_WDT:   return F("interrupt watchdog");
    case ESP_RST_TASK_WDT:  return F("task watchdog");
    case ESP_RST_WDT:       return F("watchdog");
    case ESP_RST_DEEPSLEEP: return F("deep sleep");
    case ESP_RST_BROWNOUT:  return F("brownout -- the supply dipped");
    default:                return String(F("code ")) + (int)esp_reset_reason();
  }
}

// Resolved on the board rather than left as a number for somebody else to look
// up -- the value is meant to be read by a person.
static const __FlashStringHelper *encryptionName(int index) {
  switch (WiFi.encryptionType(index)) {
    case WIFI_AUTH_OPEN:          return F("open");
    case WIFI_AUTH_WEP:           return F("WEP");
    case WIFI_AUTH_WPA_PSK:       return F("WPA");
    case WIFI_AUTH_WPA2_PSK:      return F("WPA2");
    case WIFI_AUTH_WPA_WPA2_PSK:  return F("WPA/WPA2");
    case WIFI_AUTH_WPA3_PSK:      return F("WPA3");
    case WIFI_AUTH_WPA2_WPA3_PSK: return F("WPA2/WPA3");
    default:                      return F("?");
  }
}

static void stopStation(bool radioOff) {
  WiFi.disconnect(radioOff, false);
}

// Bring the radio down and up again. A software reset leaves the WiFi hardware
// in whatever state it was in; only a power cycle clears it completely. An
// association that succeeds after pulling the plug and fails after ESP.restart()
// is what that difference looks like from the outside, so the reset is done
// here explicitly instead of being left to the next person with a USB cable.
static void restartRadio() {
  ignoreDisconnects = true;
  stopStation(true);
  WiFi.mode(WIFI_OFF);
  delay(500);
  WiFi.mode(WIFI_STA);
  applyRegulatoryDomain();
  delay(100);
  ignoreDisconnects = false;
}

// Leave the radio in a defined state before a software reset, for the same
// reason.
static void restartBoard() {
  Serial.flush();
  ignoreDisconnects = true;
  stopStation(true);
  WiFi.mode(WIFI_OFF);
  delay(200);
  ESP.restart();
}

static void startAccessPoint(bool keepTrying, bool announce = true);

// Both radio users have to get out of the way first, or the result is a list
// that looks complete and is not:
//
//   - A connect attempt parks the radio on the target channel, and a scan
//     started underneath it comes back empty.
//   - The setup access point holds the radio on its own channel and only lets
//     the scan hop away briefly. Networks on other channels then miss their
//     beacon and drop out of the list -- which is how a network that is plainly
//     there, and that other boards are connected to, can fail to show up.
//
// So the access point is taken down for the duration and put back afterwards.
static void scanNetworks() {
  bool resume = wifiSsid.length() > 0;
  bool hadAccessPoint = apMode;

  ignoreDisconnects = true;
  WiFi.mode(WIFI_STA);          // drops the soft AP if one was running
  applyRegulatoryDomain();
  WiFi.disconnect(false, false);
  delay(200);

  // A scan that collides with something else on the radio returns at once and
  // empty-handed, so an empty first result is worth a second look.
  int found = 0;
  for (int attempt = 0; attempt < 2; attempt++) {
    found = WiFi.scanNetworks(false, true);   // blocking, hidden ones included
    if (found > 0) {
      break;
    }
    WiFi.scanDelete();
    delay(500);
  }

  if (found < 0) {
    // -1 still running, -2 refused. Not a statement about the room.
    Serial.print(F("scan: failed ("));
    Serial.print(found);
    Serial.println(F("), the radio would not scan -- this says nothing about what is in range"));
  }
  else if (found == 0) {
    Serial.println(F("scan: nothing in range (2.4 GHz only -- a 5 GHz network stays invisible)"));
  }
  else {
    int configuredAt = -1;
    for (int i = 0; i < found; i++) {
      String ssid = WiFi.SSID(i);
      if (ssid == wifiSsid) {
        configuredAt = i;
      }
      Serial.print(F("scan: "));
      Serial.print(ssid.length() ? ssid : String(F("<hidden>")));
      Serial.print(F("  "));
      Serial.print(WiFi.RSSI(i));
      Serial.print(F(" dBm  ch "));
      Serial.print(WiFi.channel(i));
      Serial.print(F("  enc "));
      Serial.println(encryptionName(i));
    }

    // The one comparison worth spelling out. A name that is not on the air
    // cannot be reached with any password, so saying so here stops the search
    // before it goes down that road.
    if (wifiSsid.length() > 0) {
      if (configuredAt >= 0) {
        Serial.print(F("scan: configured network '"));
        Serial.print(wifiSsid);
        Serial.print(F("' is there, channel "));
        Serial.print(WiFi.channel(configuredAt));
        Serial.print(F(", "));
        Serial.print(WiFi.RSSI(configuredAt));
        Serial.print(F(" dBm, enc "));
        Serial.println(encryptionName(configuredAt));
      }
      else {
        Serial.print(F("scan: configured network '"));
        Serial.print(wifiSsid);
        Serial.println(F("' is NOT among them -- no password reaches a name that "
                         "is not on the air on 2.4 GHz"));
      }
    }
  }
  WiFi.scanDelete();
  ignoreDisconnects = false;

  if (hadAccessPoint) {
    startAccessPoint(true, false);   // back the way it was, without the banner
  }
  else if (resume) {
    WiFi.begin(wifiSsid.c_str(), wifiPsk.c_str());
  }
}

// Opens the setup access point. When credentials exist the station side is
// kept alive alongside it: a router that is briefly away, or comes back on a
// different channel, must not strand the board in access point mode until
// somebody walks over and power-cycles it. With AP_STA the SDK keeps retrying
// the network in the background and the access point is only a way back in.
static void startAccessPoint(bool keepTrying, bool announce) {
  apMode = true;
  WiFi.mode(keepTrying ? WIFI_AP_STA : WIFI_AP);
  applyRegulatoryDomain();
  WiFi.softAP("neato-setup");

  if (keepTrying) {
    WiFi.setAutoReconnect(true);
    WiFi.begin(wifiSsid.c_str(), wifiPsk.c_str());
  }

  if (announce) {
    Serial.print(F("access point 'neato-setup' at "));
    Serial.print(WiFi.softAPIP());
    Serial.println(keepTrying ? F(" -- still trying the configured network")
                              : F(" -- no credentials stored"));
  }
}

static bool connectAttempt(uint32_t timeoutMs) {
  WiFi.begin(wifiSsid.c_str(), wifiPsk.c_str());

  // Modem sleep parks the radio between beacons. That is fine for a board that
  // only sends, and wrong for one that has to answer: incoming connections
  // arrive late or not at all, and an access point may drop a sleeping client
  // altogether. The bridge exists to be called, so it stays awake.
  WiFi.setSleep(false);

  uint32_t deadline = millis() + timeoutMs;
  while (WiFi.status() != WL_CONNECTED && (int32_t)(millis() - deadline) < 0) {
    Serial.print('.');
    delay(200);
    yield();
  }
  Serial.println();
  return WiFi.status() == WL_CONNECTED;
}

static void setupWifi() {
  configLoad();

  if (wifiSsid.length() == 0) {
    dbg(F("no network configured"));
    startAccessPoint(false);
    return;
  }

  // The stored name, not the compile-time default: which of the two is in use
  // is exactly the question when the board does not come up on the network.
  dbg(String(F("connecting to '")) + wifiSsid + F("' (")
      + (int)wifiPsk.length() + F(" character password")
      + (seedUsed ? F(", from the flashed block)") : F(")")));

  apMode = false;
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  applyRegulatoryDomain();
  watchDisconnects();
  WiFi.setHostname(HOSTNAME);
  WiFi.setAutoReconnect(true);

  // Do not block forever -- the robot has to stay reachable over serial even
  // if the access point is down, and the SDK reconnects on its own.
  if (connectAttempt(20000)) {
    return;
  }

  // 1 = name not found, 4 = rejected (usually the password), 6 = given up.
  dbg(String(F("no connection, WiFi.status() = ")) + (int)WiFi.status());
  printDisconnectReason();

  // Second attempt on a radio that has really been off. After a software reset
  // the first one can fail on hardware state alone, and then everything after
  // it -- the reason code, the scan -- describes a fault that is not there.
  dbg(F("restarting the radio and trying once more"));
  restartRadio();
  if (connectAttempt(15000)) {
    dbg(F("connected on the second attempt -- the first failed on radio state"));
    return;
  }

  // A wrong password should not leave the board unreachable for good -- but
  // neither should a router that simply took its time.
  dbg(String(F("still no connection, WiFi.status() = ")) + (int)WiFi.status());
  printDisconnectReason();
  scanNetworks();
  startAccessPoint(true);
}

// ------------------------------------------------------- config console ----
// A line-based console on the USB port. This is what FHEM talks to right after
// flashing, while the board is still plugged into the server: no access point
// to join, no phone, no second network.
//
// SSID and password are set on their own lines so both may contain spaces --
// the value is everything after the keyword.
static String consoleLine;

static void consoleHandle(const String &line) {
  String cmd = line;
  cmd.trim();
  if (cmd.length() == 0) {
    return;
  }

  if (cmd.equalsIgnoreCase("help")) {
    Serial.println(F("wifi ssid <name>     set the network name"));
    Serial.println(F("wifi psk <password>  set the password"));
    Serial.println(F("wifi save            store both and reconnect"));
    Serial.println(F("wifi status          show what is configured"));
    Serial.println(F("wifi scan            list the networks in range"));
    Serial.println(F("wifi clear           forget the stored credentials"));
    Serial.println(F("info                 version, IP and MAC"));
    Serial.println(F("restart              reboot the board"));
    return;
  }

  if (cmd.equalsIgnoreCase("info")) {
    Serial.print(F("version ")); Serial.println(VERSION);
    Serial.print(F("mac ")); Serial.println(WiFi.macAddress());
    Serial.print(F("ip "));
    Serial.println(apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString());
    Serial.print(F("mode ")); Serial.println(apMode ? F("ap") : F("station"));
    Serial.print(F("bytes from robot ")); Serial.println(bytesFromRobot);
    Serial.print(F("link drops ")); Serial.println(linkDrops);
    Serial.print(F("uptime s ")); Serial.println(millis() / 1000);
    Serial.print(F("boot ")); Serial.println(bootReason());
    return;
  }

  if (cmd.equalsIgnoreCase("restart")) {
    Serial.println(F("OK restarting"));
    restartBoard();
    return;
  }

  if (cmd.startsWith("wifi ") || cmd.equalsIgnoreCase("wifi")) {
    String rest = cmd.substring(4);
    rest.trim();

    if (rest.startsWith("ssid")) {
      wifiSsid = rest.substring(4);
      wifiSsid.trim();
      Serial.print(F("OK ssid ")); Serial.println(wifiSsid);
      return;
    }
    if (rest.startsWith("psk")) {
      wifiPsk = rest.substring(3);
      wifiPsk.trim();
      Serial.print(F("OK psk set, ")); Serial.print(wifiPsk.length());
      Serial.println(F(" characters"));
      return;
    }
    if (rest.equalsIgnoreCase("save")) {
      if (!configSave(wifiSsid, wifiPsk)) {
        Serial.println(F("ERR ssid missing or too long"));
        return;
      }
      // Read them back before the restart. Afterwards an empty store and a
      // wrong password are indistinguishable from the outside.
      if (!configVerify(wifiSsid, wifiPsk)) {
        Serial.println(F("ERR storage did not keep the credentials"));
        return;
      }
      // Restart instead of reconnecting in place. The TCP server, mDNS and OTA
      // were all brought up against the previous network state, and rather
      // than re-initialising each of them by hand, a restart does it properly
      // -- and proves in passing that the credentials really survived.
      Serial.println(F("OK saved, restarting"));
      restartBoard();
      return;
    }
    if (rest.equalsIgnoreCase("status")) {
      Serial.print(F("ssid ")); Serial.println(wifiSsid);
      // The length, not the password: enough to see whether something ate a
      // character on the way here, and it gives nothing away that the person
      // at this console does not already have.
      Serial.print(F("psk ")); Serial.print((int)wifiPsk.length());
      Serial.println(F(" characters"));
      Serial.print(F("stored ")); Serial.println(configVerify(wifiSsid, wifiPsk) ? 1 : 0);
      Serial.print(F("connected ")); Serial.println(WiFi.status() == WL_CONNECTED ? 1 : 0);
      Serial.print(F("rssi ")); Serial.println(WiFi.RSSI());
      Serial.print(F("mac ")); Serial.println(WiFi.macAddress());
      printDisconnectReason();
      return;
    }
    if (rest.equalsIgnoreCase("scan")) {
      scanNetworks();
      Serial.println(F("OK scan done"));
      return;
    }
    if (rest.equalsIgnoreCase("clear")) {
      configClear();
      wifiSsid = "";
      wifiPsk = "";
      Serial.println(F("OK cleared, restart to take effect"));
      return;
    }
  }

  Serial.print(F("ERR unknown command: "));
  Serial.println(cmd);
}

static void consolePoll() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (consoleLine.length() > 0) {
        consoleHandle(consoleLine);
        consoleLine = "";
      }
      continue;
    }
    if (consoleLine.length() < 160) {
      consoleLine += c;
    }
  }
}

// --------------------------------------------------------------- status ----

static void sendPage(WiFiClient &http, const String &body) {
  http.print(F("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
               "Connection: close\r\nContent-Length: "));
  http.print(body.length());
  http.print(F("\r\n\r\n"));
  http.print(body);
}

static void sendStatusPage(WiFiClient &http) {
  uint32_t up = millis() / 1000;
  bool connected = client && client.connected();

  String body;
  body.reserve(1400);
  body += F("<!doctype html><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>neato_bridge</title>"
            "<style>body{font:14px system-ui,sans-serif;margin:2rem;max-width:34rem}"
            "table{border-collapse:collapse;width:100%}"
            "td{padding:.35rem .5rem;border-bottom:1px solid #ddd}"
            "td:first-child{color:#666}code{background:#f4f4f4;padding:.1rem .3rem}"
            "</style><h1>neato_bridge ");
  body += VERSION;
  body += F("</h1><table><tr><td>Board</td><td>");
  body += F("ESP32-C3, UART1 on GPIO");
  body += ROBOT_RX_PIN;
  body += F("/GPIO");
  body += ROBOT_TX_PIN;

  body += F("</td></tr><tr><td>WiFi</td><td>");
  body += WiFi.SSID();
  body += F(" (");
  body += WiFi.RSSI();
  body += F(" dBm)</td></tr><tr><td>IP</td><td>");
  body += WiFi.localIP().toString();
  body += F("</td></tr><tr><td>Uptime</td><td>");
  body += String(up / 3600) + "h " + String((up / 60) % 60) + "m " + String(up % 60) + "s";
  body += F("</td></tr><tr><td>Bridge client</td><td>");
  body += connected ? client.remoteIP().toString() : String(F("none"));
  body += F("</td></tr><tr><td>Connections</td><td>");
  body += clientCount;
  body += F("</td></tr><tr><td>Bytes to robot</td><td>");
  body += bytesToRobot;
  body += F("</td></tr><tr><td>Bytes from robot</td><td>");
  body += bytesFromRobot;

  body += F("</td></tr><tr><td>Last byte from robot</td><td>");
  if (bytesFromRobot == 0) {
    body += F("never -- check TX/RX, they must be crossed");
  } else {
    body += String((millis() - lastRobotByte) / 1000) + F("s ago");
  }
  body += F("</td></tr></table>");

  body += F("<p><a href='/test'>Send GetVersion to the robot</a> "
            "(only while no bridge client is connected)</p>"
            "<p>FHEM: <code>define Staubsauger NeatoLocal ");
  body += WiFi.localIP().toString();
  body += F(":23</code></p>");

  sendPage(http, body);
}

// A one-shot wiring test: with nobody else on the console, send GetVersion and
// show what comes back. This is what tells you the solder joints are good
// before the robot's lid goes back on.
static void sendTestPage(WiFiClient &http) {
  String body;
  body.reserve(1024);
  body += F("<!doctype html><meta charset=utf-8><title>neato_bridge test</title>"
            "<style>body{font:14px system-ui,sans-serif;margin:2rem}"
            "pre{background:#f4f4f4;padding:1rem;overflow-x:auto}</style>"
            "<h1>GetVersion</h1><pre>");

  if (client && client.connected()) {
    body += F("A bridge client is connected -- disable the FHEM device first, "
              "otherwise this would inject a command into its session.");
  } else {
    while (ROBOT.available()) {
      ROBOT.read();
    }
    ROBOT.print(F("GetVersion\n"));

    uint32_t deadline = millis() + 4000;
    size_t got = 0;
    while ((int32_t)(millis() - deadline) < 0) {
      while (ROBOT.available()) {
        char c = (char)ROBOT.read();
        got++;
        if (c == 0x1a) {          // the console's response terminator
          deadline = millis();    // done
          break;
        }
        if (c == '<') {
          body += F("&lt;");
        } else if (c == '&') {
          body += F("&amp;");
        } else if (c >= 32 || c == '\n' || c == '\r') {
          body += c;
        }
      }
      yield();
    }
    if (got == 0) {
      body += F("(nothing received -- the robot may be asleep, or TX/RX are "
                "not crossed)");
    }
  }

  body += F("</pre><p><a href='/'>back</a></p>");
  sendPage(http, body);
}

// Percent decoding for the values coming back from the setup form.
static String urlDecode(const String &in) {
  String out;
  out.reserve(in.length());
  for (size_t i = 0; i < in.length(); i++) {
    char c = in[i];
    if (c == '+') {
      out += ' ';
    } else if (c == '%' && i + 2 < in.length()) {
      out += (char) strtol(in.substring(i + 1, i + 3).c_str(), nullptr, 16);
      i += 2;
    } else {
      out += c;
    }
  }
  return out;
}

static String queryValue(const String &query, const String &key) {
  int at = query.indexOf(key + "=");
  if (at < 0) {
    return "";
  }
  int from = at + key.length() + 1;
  int to = query.indexOf('&', from);
  return urlDecode(query.substring(from, to < 0 ? query.length() : to));
}

// The setup form, served while the board runs as an access point.
static void sendSetupPage(WiFiClient &http, const String &note) {
  String body;
  body.reserve(900);
  body += F("<!doctype html><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>neato_bridge setup</title>"
            "<style>body{font:15px system-ui,sans-serif;margin:2rem;max-width:22rem}"
            "input{width:100%;padding:.5rem;margin:.3rem 0 1rem;font-size:1rem}"
            "button{padding:.6rem 1.2rem;font-size:1rem}"
            "p.note{color:#b00}</style><h1>neato_bridge</h1>");
  if (note.length()) {
    body += F("<p class=note>");
    body += note;
    body += F("</p>");
  }
  body += F("<form action='/wifi'><label>WLAN-Name</label>"
            "<input name=ssid autocapitalize=off autocorrect=off>"
            "<label>Passwort</label><input name=psk type=password>"
            "<button type=submit>Speichern</button></form>");
  sendPage(http, body);
}

static void handleHttp() {
  WiFiClient http = acceptFrom(httpServer);
  if (!http) {
    return;
  }

  uint32_t deadline = millis() + 2000;
  String line;
  while (http.connected() && (int32_t)(millis() - deadline) < 0) {
    if (http.available()) {
      char c = (char)http.read();
      if (c == '\n') {
        break;
      }
      if (c != '\r' && line.length() < 128) {
        line += c;
      }
    }
    yield();
  }

  bool handled = false;

  if (line.startsWith("GET /wifi?")) {
    int from = line.indexOf('?') + 1;
    int to = line.indexOf(' ', from);
    String query = line.substring(from, to < 0 ? line.length() : to);
    String ssid = queryValue(query, "ssid");
    String psk = queryValue(query, "psk");

    if (!configSave(ssid, psk)) {
      sendSetupPage(http, F("Name fehlt oder ist zu lang."));
    } else {
      String body = F("<!doctype html><meta charset=utf-8><title>neato_bridge</title>"
                      "<body style='font:15px system-ui,sans-serif;margin:2rem'>"
                      "<p>Gespeichert. Das Modul startet neu und verbindet sich mit ");
      body += ssid;
      body += F(".</p>");
      sendPage(http, body);
      http.flush();
      http.stop();
      delay(300);
      restartBoard();
      return;
    }
    handled = true;
  }
  else if (apMode) {
    // nothing else is reachable in this mode, so every path leads to setup
    sendSetupPage(http, "");
    handled = true;
  }

  if (!handled) {
    if (line.startsWith("GET /test")) {
      sendTestPage(http);
    } else {
      sendStatusPage(http);
    }
  }

  http.flush();
  http.stop();
}

// ------------------------------------------------------------------ setup --

void setup() {
  setupRobotSerial();

  dbg("");
  dbg(String(F("neato_bridge ")) + VERSION);
  dbg(String(F("boot: ")) + bootReason());

  setupWifi();

  if (apMode) {
    dbg(String(F("access point 'neato-setup' at ")) + WiFi.softAPIP().toString());
    dbg(F("configure with: wifi ssid <name> / wifi psk <password> / wifi save"));
  }
  else if (WiFi.status() == WL_CONNECTED) {
    dbg(String(F("connected to ")) + wifiSsid);
    dbg(String(F("IP ")) + WiFi.localIP().toString());
    dbg(String(F("status page: http://")) + WiFi.localIP().toString()
        + F("/  or http://") + HOSTNAME + F(".local/"));
    dbg(String(F("FHEM: define Staubsauger NeatoLocal "))
        + WiFi.localIP().toString() + F(":23"));
  } else {
    dbg(F("WiFi not connected -- check SSID and password. "
          "The SDK keeps retrying in the background."));
  }

  MDNS.begin(HOSTNAME);
  MDNS.addService("http", "tcp", HTTP_PORT);
  MDNS.addService("telnet", "tcp", TCP_PORT);

  ArduinoOTA.setHostname(HOSTNAME);
  ArduinoOTA.onStart([]() {
    dropClient();  // the robot must not receive a firmware image
  });
  ArduinoOTA.begin();

  bridgeServer.begin();
  bridgeServer.setNoDelay(true);  // console responses are small, latency matters
  httpServer.begin();
}

// ------------------------------------------------------------------- loop --

// The station side is supervised rather than trusted. Automatic reconnect
// covers the ordinary case, but a mesh that hands the board to another access
// point, or a radio that comes back in a state the SDK does not recover from,
// both end with a bridge that is simply gone -- and nobody is standing next to
// the robot to notice. Costing the console half a second is the better trade.
static uint32_t lastLinkCheck = 0;
static uint32_t offlineSince = 0;
static uint8_t recoveryAttempts = 0;

static void superviseLink() {
  if (apMode || wifiSsid.length() == 0) {
    return;                       // the access point is its own way back in
  }
  if (millis() - lastLinkCheck < 5000) {
    return;
  }
  lastLinkCheck = millis();

  if (WiFi.status() == WL_CONNECTED) {
    offlineSince = 0;
    recoveryAttempts = 0;
    return;
  }

  // Give the SDK its own chance first -- a brief drop is not worth a reset.
  if (offlineSince == 0) {
    offlineSince = millis();
    linkDrops++;
    return;
  }
  if (millis() - offlineSince < 30000) {
    return;
  }

  offlineSince = 0;
  recoveryAttempts++;
  dbg(String(F("link down for 30 s, recovery attempt ")) + recoveryAttempts);

  if (recoveryAttempts >= 4) {
    dbg(F("no link after four attempts -- opening the setup access point"));
    startAccessPoint(true);
    recoveryAttempts = 0;
    return;
  }

  restartRadio();
  WiFi.begin(wifiSsid.c_str(), wifiPsk.c_str());
}

void loop() {
  ArduinoOTA.handle();
  superviseLink();
  consolePoll();
  handleHttp();

  // Accept a new connection. A single client owns the console; a fresh
  // connection takes over from a stale one rather than being refused, so a
  // restarted FHEM always gets back in.
  if (bridgeServer.hasClient()) {
    WiFiClient incoming = acceptFrom(bridgeServer);
    if (client && client.connected()) {
      dropClient();
    }
    client = incoming;
    client.setNoDelay(true);
    lastClientActivity = millis();
    clientCount++;

    // discard console output that arrived while nobody was listening
    while (ROBOT.available()) {
      ROBOT.read();
    }
  }

  if (client && !client.connected()) {
    dropClient();
  }

  // network -> robot
  if (client && client.connected()) {
    uint8_t buf[256];
    size_t n = 0;
    while (client.available() && n < sizeof(buf)) {
      buf[n++] = client.read();
    }
    if (n > 0) {
      ROBOT.write(buf, n);
      bytesToRobot += n;
      lastClientActivity = millis();
    }
  }

  // robot -> network
  if (ROBOT.available()) {
    uint8_t buf[256];
    size_t n = 0;
    while (ROBOT.available() && n < sizeof(buf)) {
      buf[n++] = ROBOT.read();
    }
    if (n > 0) {
      bytesFromRobot += n;
      lastRobotByte = millis();
      if (client && client.connected()) {
        client.write(buf, n);
      }
    }
  }

  if (IDLE_TIMEOUT_MS > 0 && client && client.connected() &&
      (millis() - lastClientActivity) > IDLE_TIMEOUT_MS) {
    dropClient();
  }

  yield();
}
