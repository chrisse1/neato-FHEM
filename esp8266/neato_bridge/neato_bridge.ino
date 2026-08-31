/*
 * neato_bridge -- transparent WiFi-to-serial bridge for Neato Botvac robots.
 *
 * Bridges a TCP connection to the robot's serial console, which is exactly what
 * 74_NeatoLocal.pm expects on its TCP transport:
 *
 *     define Staubsauger NeatoLocal <ip-of-this-esp>:23
 *
 * The bridge stays deliberately dumb: it does not parse, buffer by command or
 * rewrite anything, so the FHEM module keeps full control of the console. The
 * one exception is a safety net -- when a client disconnects, "TestMode Off" is
 * sent to the robot, because a robot left in test mode ignores its own buttons
 * and refuses to clean.
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
 * reaches the robot's console.
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

static const char *HOSTNAME = "neato";     // reachable as neato.local
static const uint16_t TCP_PORT = 23;       // must match the FHEM define
static const uint32_t ROBOT_BAUD = 115200; // the console speaks 115200 8N1

// Drop a client that has been silent for this long, so a crashed FHEM does not
// block the single connection slot forever. 0 disables the timeout.
static const uint32_t IDLE_TIMEOUT_MS = 15UL * 60UL * 1000UL;

// ------------------------------------------------------------------ state --

static WiFiServer server(TCP_PORT);
static WiFiClient client;
static uint32_t lastClientActivity = 0;

// --------------------------------------------------------------- helpers ---

// Leave the robot in a usable state: in test mode it ignores its buttons and
// will not clean, so we never let a disconnect strand it there.
static void leaveTestMode() {
  Serial.print(F("TestMode Off\n"));
  Serial.flush();
}

static void dropClient(const __FlashStringHelper *reason) {
  if (!client) {
    return;
  }
  leaveTestMode();
  client.stop();
  (void)reason;
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
    delay(200);
    yield();
  }
}

// ------------------------------------------------------------------ setup --

void setup() {
  Serial.setRxBufferSize(1024);  // has to be set before the port is opened
  Serial.begin(ROBOT_BAUD);
  Serial.swap();                 // UART0 -> GPIO13 (RX) / GPIO15 (TX)

  setupWifi();

  MDNS.begin(HOSTNAME);
  MDNS.addService("telnet", "tcp", TCP_PORT);

  ArduinoOTA.setHostname(HOSTNAME);
  ArduinoOTA.onStart([]() {
    // the robot must not receive a firmware image
    dropClient(F("ota"));
  });
  ArduinoOTA.begin();

  server.begin();
  server.setNoDelay(true);  // console responses are small, latency matters
}

// ------------------------------------------------------------------- loop --

void loop() {
  ArduinoOTA.handle();
  MDNS.update();

  // Accept a new connection. A single client owns the console; a fresh
  // connection takes over from a stale one rather than being refused, so a
  // restarted FHEM always gets back in.
  if (server.hasClient()) {
#if defined(ARDUINO_ESP8266_MAJOR) && ARDUINO_ESP8266_MAJOR >= 3
    WiFiClient incoming = server.accept();
#else
    WiFiClient incoming = server.available();  // pre-3.0 core spelling
#endif
    if (client && client.connected()) {
      dropClient(F("replaced"));
    }
    client = incoming;
    client.setNoDelay(true);
    lastClientActivity = millis();

    // discard console output that arrived while nobody was listening
    while (Serial.available()) {
      Serial.read();
    }
  }

  if (client && !client.connected()) {
    dropClient(F("disconnected"));
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
    if (n > 0 && client && client.connected()) {
      client.write(buf, n);
    }
  }

  if (IDLE_TIMEOUT_MS > 0 && client && client.connected() &&
      (millis() - lastClientActivity) > IDLE_TIMEOUT_MS) {
    dropClient(F("idle"));
  }

  yield();
}
