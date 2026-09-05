/*
 * neato_bridge -- transparent WiFi-to-serial bridge for Neato Botvac robots.
 *
 * Bridges a TCP connection to the robot's serial console, which is exactly what
 * 74_NeatoLocal.pm expects on its TCP transport:
 *
 *     define Staubsauger NeatoLocal <ip-of-this-esp>:23
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
 * Target: ESP8266 (tested layout: NodeMCU LoLin V3 / ESP-12F, 4 MB flash).
 *
 * WIRING (ESP8266 side, UART0 swapped to the secondary pins)
 *
 *     Robot TX  -> D7 / GPIO13   (ESP RX)
 *     Robot RX  <- D8 / GPIO15   (ESP TX)
 *     Robot GND -- GND
 *     Robot 3V3 -> 3V3 pin       (NOT Vin/VU -- that would feed the regulator)
 *
 * Why the swap: UART0 normally sits on GPIO1/GPIO3, which is also where the
 * ESP8266 boot ROM prints its startup chatter at 74880 baud. Serial.swap()
 * moves the port to GPIO13/GPIO15 after boot, so none of that noise ever
 * reaches the robot's console. Everything this sketch prints before the swap
 * goes to the USB serial monitor -- that is your only feedback while flashing,
 * so watch it at 115200 baud.
 *
 * GPIO15 carries the usual boot pulldown, so the robot's RX line sits low until
 * this sketch starts. That is a harmless break condition for the console.
 *
 * POWER: flash over USB with the robot disconnected, then unplug USB before
 * connecting the robot's 3.3 V. Never feed both at once -- the board regulator
 * and the robot would fight over the same rail. A 220 uF electrolytic plus
 * 100 nF across 3V3/GND right at the module absorbs the WiFi transmit peaks,
 * which are noticeably higher on an ESP8266 than on an ESP32-C3.
 *
 * Part of https://github.com/chrisse1/neato-FHEM
 */

#include <ESP8266WiFi.h>
#include <ESP8266mDNS.h>
#include <ArduinoOTA.h>

// ---------------------------------------------------------------- config ---

#ifndef WIFI_SSID
#define WIFI_SSID "your-ssid"
#endif
#ifndef WIFI_PSK
#define WIFI_PSK "your-password"
#endif

static const char *VERSION = "0.2.0";
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

// --------------------------------------------------------------- helpers ---

// Leave the robot in a usable state: in test mode it ignores its buttons and
// will not clean, so we never let a disconnect strand it there.
static void leaveTestMode() {
  Serial.print(F("TestMode Off\n"));
  Serial.flush();
}

static void dropClient() {
  if (!client) {
    return;
  }
  leaveTestMode();
  client.stop();
}

static void setupWifi() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.hostname(HOSTNAME);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PSK);

  // Do not block forever -- the robot has to stay reachable over serial even
  // if the access point is down, and the SDK reconnects on its own.
  uint32_t deadline = millis() + 20000;
  while (WiFi.status() != WL_CONNECTED && (int32_t)(millis() - deadline) < 0) {
    Serial.print('.');
    delay(200);
    yield();
  }
  Serial.println();
}

// --------------------------------------------------------------- status ----

static void sendStatusPage(WiFiClient &http) {
  uint32_t up = millis() / 1000;
  bool connected = client && client.connected();

  String body;
  body.reserve(1200);
  body += F("<!doctype html><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>neato_bridge</title>"
            "<style>body{font:14px system-ui,sans-serif;margin:2rem;max-width:34rem}"
            "table{border-collapse:collapse;width:100%}"
            "td{padding:.35rem .5rem;border-bottom:1px solid #ddd}"
            "td:first-child{color:#666}code{background:#f4f4f4;padding:.1rem .3rem}"
            "</style><h1>neato_bridge ");
  body += VERSION;
  body += F("</h1><table>");

  body += F("<tr><td>WiFi</td><td>");
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

  http.print(F("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
               "Connection: close\r\nContent-Length: "));
  http.print(body.length());
  http.print(F("\r\n\r\n"));
  http.print(body);
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
    while (Serial.available()) {
      Serial.read();
    }
    Serial.print(F("GetVersion\n"));

    uint32_t deadline = millis() + 4000;
    size_t got = 0;
    while ((int32_t)(millis() - deadline) < 0) {
      while (Serial.available()) {
        char c = (char)Serial.read();
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

  http.print(F("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
               "Connection: close\r\nContent-Length: "));
  http.print(body.length());
  http.print(F("\r\n\r\n"));
  http.print(body);
}

static void handleHttp() {
#if defined(ARDUINO_ESP8266_MAJOR) && ARDUINO_ESP8266_MAJOR >= 3
  WiFiClient http = httpServer.accept();
#else
  WiFiClient http = httpServer.available();
#endif
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
  Serial.setRxBufferSize(1024);  // has to be set before the port is opened
  Serial.begin(ROBOT_BAUD);

  // Everything up to Serial.swap() goes out of the USB port, which is the only
  // feedback available while flashing.
  Serial.println();
  Serial.print(F("\nneato_bridge "));
  Serial.println(VERSION);
  Serial.print(F("connecting to "));
  Serial.println(F(WIFI_SSID));

  setupWifi();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print(F("connected, IP "));
    Serial.println(WiFi.localIP());
    Serial.print(F("status page: http://"));
    Serial.print(WiFi.localIP());
    Serial.print(F("/  or http://"));
    Serial.print(HOSTNAME);
    Serial.println(F(".local/"));
    Serial.print(F("FHEM: define Staubsauger NeatoLocal "));
    Serial.print(WiFi.localIP());
    Serial.println(F(":23"));
  } else {
    Serial.println(F("WiFi not connected -- check SSID and password. "
                     "The SDK keeps retrying in the background."));
  }

  Serial.println(F("switching UART0 to GPIO13/GPIO15 now; this is the last "
                   "message on the USB port. Use the status page from here on."));
  Serial.flush();
  delay(50);

  Serial.swap();  // UART0 -> GPIO13 (RX) / GPIO15 (TX)

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
  MDNS.update();
  handleHttp();

  // Accept a new connection. A single client owns the console; a fresh
  // connection takes over from a stale one rather than being refused, so a
  // restarted FHEM always gets back in.
  if (bridgeServer.hasClient()) {
#if defined(ARDUINO_ESP8266_MAJOR) && ARDUINO_ESP8266_MAJOR >= 3
    WiFiClient incoming = bridgeServer.accept();
#else
    WiFiClient incoming = bridgeServer.available();  // pre-3.0 core spelling
#endif
    if (client && client.connected()) {
      dropClient();
    }
    client = incoming;
    client.setNoDelay(true);
    lastClientActivity = millis();
    clientCount++;

    // discard console output that arrived while nobody was listening
    while (Serial.available()) {
      Serial.read();
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
      Serial.write(buf, n);
      bytesToRobot += n;
      lastClientActivity = millis();
    }
  }

  // robot -> network
  if (Serial.available()) {
    uint8_t buf[256];
    size_t n = 0;
    while (Serial.available() && n < sizeof(buf)) {
      buf[n++] = Serial.read();
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
