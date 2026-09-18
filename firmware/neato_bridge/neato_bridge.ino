/*
 * neato_bridge -- transparent WiFi-to-serial bridge for Neato Botvac robots.
 *
 * Bridges a TCP connection to the robot's serial console, which is exactly what
 * 74_NeatoLocal.pm expects on its TCP transport:
 *
 *     define Staubsauger NeatoLocal <ip-of-this-board>:23
 *
 * Builds for both boards from the same source:
 *
 *   ESP32-C3  (recommended, e.g. "Super Mini")  -- fqbn esp32:esp32:esp32c3
 *   ESP8266   (NodeMCU LoLin V3, ESP-12F)       -- fqbn esp8266:esp8266:nodemcuv2
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
 *   ESP32-C3        Robot TX -> GPIO4 (RX)    Robot RX <- GPIO5 (TX)
 *   ESP8266         Robot TX -> D7/GPIO13     Robot RX <- D8/GPIO15
 *   both            GND -- GND,  robot 3.3V -> the board's 3V3 pin
 *
 * Never feed the board from USB and the robot at the same time: flash over USB
 * with the robot disconnected, unplug USB, then connect the robot. A 220 uF
 * electrolytic plus 100 nF across 3V3/GND at the module absorbs the WiFi
 * transmit peaks.
 *
 * Serial layout differs per board, and that difference is the reason the C3 is
 * the nicer target:
 *
 *   ESP32-C3  A dedicated UART (Serial1) talks to the robot while the USB CDC
 *             port stays free, so the serial monitor keeps working forever.
 *   ESP8266   Only one usable UART. Serial.swap() moves it off GPIO1/GPIO3 --
 *             where the boot ROM prints its startup chatter at 74880 baud --
 *             onto GPIO13/GPIO15. After the swap the USB port is dead, so
 *             everything this sketch prints before it is your only feedback
 *             while flashing. Watch the monitor at 115200 baud.
 *
 * Part of https://github.com/chrisse1/neato-FHEM
 */

#if defined(ARDUINO_ARCH_ESP8266)
  #include <ESP8266WiFi.h>
  #include <ESP8266mDNS.h>
  #include <ArduinoOTA.h>
  extern "C" {
    #include <user_interface.h>   // wifi_set_country()
  }
  #define ROBOT Serial          // UART0, moved to GPIO13/GPIO15 in setup()
#elif defined(ARDUINO_ARCH_ESP32)
  #include <WiFi.h>
  #include <ESPmDNS.h>
  #include <ArduinoOTA.h>
  #include <Preferences.h>
  #include <esp_wifi.h>         // esp_wifi_set_country_code()
  #define ROBOT Serial1         // dedicated UART, USB CDC stays free
  #define HAVE_CONFIG_STORE 1   // credentials live in NVS, not in this file
#else
  #error "neato_bridge targets ESP8266 or ESP32"
#endif

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

static const char *VERSION = "0.7.0";
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

// On the ESP8266 the debug port and the robot port are the same UART, so once
// the swap has happened nothing may be printed any more -- it would land in the
// robot's console. On the ESP32 the USB port stays ours for good.
static bool debugUsable = true;

// The credentials the board is actually using. On the ESP32 they are kept in
// NVS so one prebuilt image fits every network; the #defines above only serve
// as a fallback for a self-compiled binary. The ESP8266 has no NVS and no
// spare serial port, so there they stay compile-time values.
static String wifiSsid;
static String wifiPsk;
static bool apMode = false;     // no credentials: running as an access point

#if HAVE_CONFIG_STORE
static Preferences prefs;
#endif

// What a freshly flashed image carries when nobody filled the defines in.
static bool isPlaceholder(const String &ssid) {
  return ssid.length() == 0 || ssid == "your-ssid";
}

static void configLoad() {
#if HAVE_CONFIG_STORE
  prefs.begin("neato", true);
  wifiSsid = prefs.getString("ssid", "");
  wifiPsk = prefs.getString("psk", "");
  prefs.end();
#endif
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
#if HAVE_CONFIG_STORE
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
#else
  (void)ssid;
  (void)psk;
  return false;   // nowhere to put them
#endif
}

// Read the credentials straight back out of the store. Saving reports success
// even when the partition is full or missing, and a board that silently keeps
// nothing looks exactly like a wrong password after the next restart.
static bool configVerify(const String &ssid, const String &psk) {
#if HAVE_CONFIG_STORE
  prefs.begin("neato", true);
  String storedSsid = prefs.getString("ssid", "");
  String storedPsk = prefs.getString("psk", "");
  prefs.end();
  return storedSsid == ssid && storedPsk == psk;
#else
  (void)ssid;
  (void)psk;
  return false;
#endif
}

static void configClear() {
#if HAVE_CONFIG_STORE
  prefs.begin("neato", false);
  prefs.clear();
  prefs.end();
#endif
}

// --------------------------------------------------------------- helpers ---

static void dbg(const String &line) {
  if (debugUsable) {
    Serial.println(line);
  }
}

// Accept a pending connection. The spelling changed across core versions.
static WiFiClient acceptFrom(WiFiServer &server) {
#if defined(ARDUINO_ARCH_ESP8266) && defined(ARDUINO_ESP8266_MAJOR) && ARDUINO_ESP8266_MAJOR < 3
  return server.available();  // pre-3.0 core spelling
#else
  return server.accept();
#endif
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
#if defined(ARDUINO_ARCH_ESP8266)
  Serial.setRxBufferSize(1024);  // has to be set before the port is opened
  Serial.begin(ROBOT_BAUD);
#else
  Serial.begin(115200);          // USB CDC, stays available
  Serial1.setRxBufferSize(1024);
  Serial1.begin(ROBOT_BAUD, SERIAL_8N1, ROBOT_RX_PIN, ROBOT_TX_PIN);
#endif
}

// ESP8266 only: hand UART0 over to the robot. Everything printed after this
// would go down the robot's throat, so debug output ends here.
static void handOverSerial() {
#if defined(ARDUINO_ARCH_ESP8266)
  Serial.println(F("switching UART0 to GPIO13/GPIO15 now; this is the last "
                   "message on the USB port. Use the status page from here on."));
  Serial.flush();
  delay(50);
  Serial.swap();
  debugUsable = false;
#endif
}

// Must be applied after the radio is up, i.e. after WiFi.mode(), and again
// whenever the mode changes.
static void applyRegulatoryDomain() {
#if defined(ARDUINO_ARCH_ESP8266)
  wifi_country_t country;
  memcpy(country.cc, WIFI_COUNTRY, 3);
  country.schan = 1;
  country.nchan = 13;
  country.policy = WIFI_COUNTRY_POLICY_MANUAL;
  wifi_set_country(&country);
#else
  // true: follow the access point's own country information once associated.
  esp_wifi_set_country_code(WIFI_COUNTRY, true);
#endif
}

// What the board can actually see. A network that only exists on 5 GHz, and a
// board whose antenna barely reaches the router, both look exactly like a
// wrong password from the outside -- the scan tells them apart.
//
// The station side has to be stopped first. While it works through a connect
// attempt the radio sits on the target channel, and a scan started underneath
// it comes back empty -- which reads like an empty room instead of a locked
// door. The attempt is picked up again at the end.
static void scanNetworks() {
  if (!debugUsable) {
    return;
  }

  bool resume = wifiSsid.length() > 0;
#if defined(ARDUINO_ARCH_ESP8266)
  WiFi.disconnect(false);
#else
  WiFi.disconnect(false, false);
#endif
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
    for (int i = 0; i < found; i++) {
      String ssid = WiFi.SSID(i);
      Serial.print(F("scan: "));
      Serial.print(ssid.length() ? ssid : String(F("<hidden>")));
      Serial.print(F("  "));
      Serial.print(WiFi.RSSI(i));
      Serial.print(F(" dBm  ch "));
      Serial.print(WiFi.channel(i));
      Serial.print(F("  enc "));
      Serial.println((int)WiFi.encryptionType(i));
    }
  }
  WiFi.scanDelete();

  if (resume) {
    WiFi.begin(wifiSsid.c_str(), wifiPsk.c_str());
  }
}

// Opens the setup access point. When credentials exist the station side is
// kept alive alongside it: a router that is briefly away, or comes back on a
// different channel, must not strand the board in access point mode until
// somebody walks over and power-cycles it. With AP_STA the SDK keeps retrying
// the network in the background and the access point is only a way back in.
static void startAccessPoint(bool keepTrying) {
  apMode = true;
  WiFi.mode(keepTrying ? WIFI_AP_STA : WIFI_AP);
  applyRegulatoryDomain();
  WiFi.softAP("neato-setup");

  if (keepTrying) {
    WiFi.setAutoReconnect(true);
    WiFi.begin(wifiSsid.c_str(), wifiPsk.c_str());
  }

  if (debugUsable) {
    Serial.print(F("access point 'neato-setup' at "));
    Serial.print(WiFi.softAPIP());
    Serial.println(keepTrying ? F(" -- still trying the configured network")
                              : F(" -- no credentials stored"));
  }
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
      + (int)wifiPsk.length() + F(" character password)"));

  apMode = false;
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  applyRegulatoryDomain();
#if defined(ARDUINO_ARCH_ESP8266)
  WiFi.hostname(HOSTNAME);
#else
  WiFi.setHostname(HOSTNAME);
#endif
  WiFi.setAutoReconnect(true);
  WiFi.begin(wifiSsid.c_str(), wifiPsk.c_str());

  // Do not block forever -- the robot has to stay reachable over serial even
  // if the access point is down, and the SDK reconnects on its own.
  uint32_t deadline = millis() + 20000;
  while (WiFi.status() != WL_CONNECTED && (int32_t)(millis() - deadline) < 0) {
    if (debugUsable) {
      Serial.print('.');
    }
    delay(200);
    yield();
  }
  if (debugUsable) {
    Serial.println();
  }

  // A wrong password should not leave the board unreachable for good -- but
  // neither should a router that simply took its time.
  if (WiFi.status() != WL_CONNECTED) {
    // 1 = name not found, 4 = rejected (usually the password), 6 = given up.
    dbg(String(F("no connection, WiFi.status() = ")) + (int)WiFi.status());
    scanNetworks();
    startAccessPoint(true);
  }
}

// ------------------------------------------------------- config console ----
#if HAVE_CONFIG_STORE
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
    return;
  }

  if (cmd.equalsIgnoreCase("restart")) {
    Serial.println(F("OK restarting"));
    Serial.flush();
    delay(100);
    ESP.restart();
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
      Serial.flush();
      delay(200);
      ESP.restart();
      return;
    }
    if (rest.equalsIgnoreCase("status")) {
      Serial.print(F("ssid ")); Serial.println(wifiSsid);
      Serial.print(F("psk ")); Serial.println(wifiPsk.length() ? F("set") : F("empty"));
      Serial.print(F("stored ")); Serial.println(configVerify(wifiSsid, wifiPsk) ? 1 : 0);
      Serial.print(F("connected ")); Serial.println(WiFi.status() == WL_CONNECTED ? 1 : 0);
      Serial.print(F("rssi ")); Serial.println(WiFi.RSSI());
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
#endif  // HAVE_CONFIG_STORE

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
#if defined(ARDUINO_ARCH_ESP8266)
  body += F("ESP8266, UART0 on GPIO13/GPIO15");
#else
  body += F("ESP32, UART1 on GPIO");
  body += ROBOT_RX_PIN;
  body += F("/GPIO");
  body += ROBOT_TX_PIN;
#endif

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

#if HAVE_CONFIG_STORE
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
#endif  // HAVE_CONFIG_STORE

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

#if HAVE_CONFIG_STORE
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
      ESP.restart();
      return;
    }
    handled = true;
  }
  else if (apMode) {
    // nothing else is reachable in this mode, so every path leads to setup
    sendSetupPage(http, "");
    handled = true;
  }
#endif

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

  handOverSerial();  // ESP8266 only; the C3 keeps its USB port

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

void loop() {
  ArduinoOTA.handle();
#if HAVE_CONFIG_STORE
  consolePoll();
#endif
#if defined(ARDUINO_ARCH_ESP8266)
  MDNS.update();
#endif
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
