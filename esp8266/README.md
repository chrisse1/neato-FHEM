# WLAN-Brücke für ESP8266

`neato_bridge` ist eine bewusst dumme Brücke: TCP rein, serielle Konsole raus,
ohne zu parsen. Die gesamte Logik bleibt im FHEM-Modul.

Getestet mit dem Layout des NodeMCU LoLin V3 (ESP-12F, 4 MB Flash), läuft auf
jedem ESP8266 mit ≥ 1 MB.

## Verdrahtung

UART0 wird per `Serial.swap()` auf die Zweitpins gelegt, damit der Boot-Müll
des ESP (74880 Baud auf GPIO1) nicht in der Roboterkonsole landet.

| Roboter | Lolin V3 |
|---|---|
| TX | D7 / GPIO13 (RX) |
| RX | D8 / GPIO15 (TX) |
| GND | GND |
| 3.3V | **3V3** – nicht Vin/VU |

## Strom

1. Erst über USB flashen, Roboter dabei **nicht** angeschlossen.
2. USB abziehen.
3. Dann 3,3 V vom Roboter an den 3V3-Pin.

Nie beides gleichzeitig – sonst treiben der Bordregler (AMS1117) und der
Roboter dieselbe Schiene gegeneinander.

220 µF Elko + 100 nF direkt am Modul zwischen 3V3 und GND spendieren. Der
ESP8266 zieht beim Senden deutlich höhere Spitzen als ein ESP32-C3, und die
3,3-V-Schiene des Roboters ist nicht dafür ausgelegt worden.

## Flashen

**Roboter dabei nicht angeschlossen.**

1. Arduino IDE, Boardverwalter-URL eintragen:
   `http://arduino.esp8266.com/stable/package_esp8266com_index.json`,
   dann „esp8266 by ESP8266 Community" installieren.
2. Board: **NodeMCU 1.0 (ESP-12E Module)**. Flash Size 4MB, Upload Speed 115200
   (falls der Upload abbricht: runter auf 57600).
3. Der LoLin V3 hat einen CH340 – unter Linux ist der Treiber dabei, das Board
   erscheint als `/dev/ttyUSB0`. Deinen Benutzer ggf. in die Gruppe `dialout`.
4. Oben in `neato_bridge.ino` `WIFI_SSID` und `WIFI_PSK` eintragen.
5. Hochladen, dann **seriellen Monitor auf 115200 Baud** öffnen und Reset
   drücken. Dort steht, ob das WLAN klappt und unter welcher IP die Brücke
   erreichbar ist:

```
neato_bridge 0.2.0
connecting to MeinWLAN
...
connected, IP 192.168.1.57
status page: http://192.168.1.57/  or http://neato.local/
FHEM: define Staubsauger NeatoLocal 192.168.1.57:23
switching UART0 to GPIO13/GPIO15 now; this is the last message on the USB port.
```

Ab dieser letzten Zeile ist der serielle Monitor tot – die UART gehört jetzt
dem Roboter. Alles Weitere läuft über die Statusseite.

## Verifizierter Build

Die CI übersetzt den Sketch bei jedem Push für `nodemcuv2` mit ESP8266-Core
**3.1.2**. Belegung des aktuellen Stands:

| Bereich | Belegt | Verfügbar |
|---|---|---|
| Code im Flash | 291 KB | 1024 KB |
| RAM (global/statisch) | 28,9 KB | 80,2 KB |
| IRAM | 60,8 KB | 64 KB (92 %) |

Der Flash-Verbrauch ist der Grund, bei der Board-Einstellung **4MB (FS:2MB
OTA:~1019KB)** zu bleiben: 291 KB passen bequem in die OTA-Hälfte, spätere
Updates über die Luft funktionieren also. Die 92 % IRAM sind für einen ESP8266
mit WLAN normal, aber der Grund, warum hier keine weiteren Bibliotheken
dazukommen sollten.

Kompiliert wird gegen Core 3.x; der Zweig für Core 2.x (`server.available()`
statt `accept()`) ist nur mitgeführt, nicht getestet.

## Statusseite

`http://neato.local/` zeigt WLAN, IP, Laufzeit, ob FHEM verbunden ist und die
Byte-Zähler in beide Richtungen. **„Bytes from robot: 0" heißt: die Verdrahtung
stimmt nicht** – meist sind TX und RX nicht gekreuzt.

`/test` schickt einmalig `GetVersion` an den Roboter und zeigt die Antwort.
Das ist der schnellste Weg, die Lötstellen zu prüfen, bevor der Deckel
wieder zugeht. Es läuft nur, wenn gerade kein FHEM verbunden ist – sonst
würde es sich in dessen Sitzung drängeln.

## Bauen per Kommandozeile

Arduino IDE mit ESP8266-Core, Board „NodeMCU 1.0 (ESP-12E Module)“.
SSID und Passwort oben in der `.ino` eintragen, oder beim Kompilieren setzen:

```
-DWIFI_SSID="\"MeinWLAN\"" -DWIFI_PSK="\"geheim\""
```

Nach dem ersten Flashen geht es per OTA weiter (Hostname `neato`) – praktisch,
wenn das Modul erst einmal im Roboter verklebt ist.

## In FHEM

```
define Staubsauger NeatoLocal neato.local:23
```

oder mit IP statt mDNS-Name.

## Verhalten

* Ein Client zur Zeit. Eine neue Verbindung übernimmt und trennt die alte –
  ein neu gestartetes FHEM kommt so immer wieder rein.
* Bei Verbindungsabbruch, Übernahme, Leerlauf-Timeout und vor einem
  OTA-Update sendet die Brücke `TestMode Off` an den Roboter. Ein Roboter im
  Testmodus reagiert weder auf seine Tasten noch reinigt er – dort darf er
  nicht hängenbleiben.
* Fällt das WLAN aus, bootet die Brücke nicht neu, sondern wartet auf den
  Reconnect des SDK.
