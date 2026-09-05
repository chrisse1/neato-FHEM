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
  #define ROBOT Serial          // UART0, moved to GPIO13/GPIO15 in setup()
#elif defined(ARDUINO_ARCH_ESP32)
  #include <WiFi.h>
  #include <ESPmDNS.h>
  #include <ArduinoOTA.h>
  #define ROBOT Serial1         // dedicated UART, USB CDC stays free
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

// ESP32 only: the pins the robot's debug header is wired to. GPIO4/GPIO5 are
// free on the C3 Super Mini and, unlike GPIO20/GPIO21, never collide with the
// board's own console.
#ifndef ROBOT_RX_PIN
#define ROBOT_RX_PIN 4
#endif
#ifndef ROBOT_TX_PIN
#define ROBOT_TX_PIN 5
#endif

static const char *VERSION = "0.3.0";
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

static void setupWifi() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
#if defined(ARDUINO_ARCH_ESP8266)
  WiFi.hostname(HOSTNAME);
#else
  WiFi.setHostname(HOSTNAME);
#endif
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PSK);

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

  if (line.startsWith("GET /test")) {
    sendTestPage(http);
  } else {
    sendStatusPage(http);
  }

  http.flush();
  http.stop();
}

// ------------------------------------------------------------------ setup --

void setup() {
  setupRobotSerial();

  dbg("");
  dbg(String(F("neato_bridge ")) + VERSION);
  dbg(String(F("connecting to ")) + WIFI_SSID);

  setupWifi();

  if (WiFi.status() == WL_CONNECTED) {
    dbg(String(F("connected, IP ")) + WiFi.localIP().toString());
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
