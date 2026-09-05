# WLAN-Brücke für den Roboter

`neato_bridge` ist eine bewusst dumme Brücke: TCP rein, serielle Konsole raus,
ohne zu parsen. Die gesamte Logik bleibt im FHEM-Modul.

Ein Sketch, zwei Boards:

| Board | FQBN | Anmerkung |
|---|---|---|
| **ESP32-C3** (z. B. Super Mini) | `esp32:esp32:esp32c3` | empfohlen |
| ESP8266 (NodeMCU LoLin V3, ESP-12F) | `esp8266:esp8266:nodemcuv2` | funktioniert, mit Einschränkungen |

## Warum der C3 die bessere Wahl ist

Der ESP8266 hat nur **eine** brauchbare UART. Die liegt normal auf GPIO1/GPIO3,
wo das Boot-ROM beim Reset seinen Startmüll mit 74880 Baud ausgibt – der würde
in der Roboterkonsole landen. `Serial.swap()` legt sie deshalb auf
GPIO13/GPIO15. Der Preis: **danach ist der serielle Monitor tot**, weil es
dieselbe Schnittstelle ist. Diagnose nur noch über die Statusseite.

Der C3 hat eine eigene UART für den Roboter, während der USB-CDC-Port frei
bleibt. Der serielle Monitor funktioniert also dauerhaft. Dazu ist er kleiner
und zieht weniger Strom aus der 3,3-V-Schiene des Roboters.

## Verdrahtung

Der Debug-Header im Roboter ist `RX | 3.3V | TX | GND` (von links). TX und RX
werden **gekreuzt**:

| Roboter | ESP32-C3 | ESP8266 |
|---|---|---|
| TX | GPIO4 (RX) | D7 / GPIO13 |
| RX | GPIO5 (TX) | D8 / GPIO15 |
| GND | GND | GND |
| 3.3V | **3V3** | **3V3** |

Beim C3 sind die Pins über `ROBOT_RX_PIN` und `ROBOT_TX_PIN` einstellbar.
GPIO4/GPIO5 sind beim Super Mini frei und kollidieren – anders als GPIO20/21 –
nicht mit der Konsole des Boards.

## Strom

1. Erst über USB flashen, Roboter dabei **nicht** angeschlossen.
2. USB abziehen.
3. Dann 3,3 V vom Roboter an den 3V3-Pin.

Nie beides gleichzeitig – sonst treiben der Bordregler und der Roboter
dieselbe Schiene gegeneinander. 220 µF Elko plus 100 nF direkt am Modul
zwischen 3V3 und GND spendieren; die Sendespitzen sind beim ESP8266 deutlich
höher als beim C3.

## Flashen

**Roboter dabei nicht angeschlossen.**

### ESP32-C3

Ausführlich in [docs/flashing-esp32c3.md](../docs/flashing-esp32c3.md), kurz:

1. Boardverwalter-URL
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`,
   dann „esp32 by Espressif Systems" installieren.
2. Board: **Nologo ESP32C3 Super Mini** (hat USB CDC fest an) oder
   **ESP32C3 Dev Module** mit **USB CDC On Boot: Enabled** – sonst bleibt der
   serielle Monitor stumm.
3. Partition Scheme **„Minimal SPIFFS (1.9MB APP with OTA/128KB SPIFFS)"** –
   der Sketch belegt sonst 79 % der App-Partition.
4. Der C3 meldet sich per nativem USB, meist als `/dev/ttyACM0`.
5. Oben in `neato_bridge.ino` `WIFI_SSID` und `WIFI_PSK` eintragen.
6. Hochladen, seriellen Monitor auf 115200 öffnen. Startet der Upload nicht:
   BOOT halten, RESET tippen, BOOT loslassen.

### ESP8266

1. Boardverwalter-URL
   `http://arduino.esp8266.com/stable/package_esp8266com_index.json`,
   dann „esp8266 by ESP8266 Community" installieren.
2. Board: **NodeMCU 1.0 (ESP-12E Module)**, Flash Size **4MB (FS:2MB
   OTA:~1019KB)**, Upload Speed 115200 (bei Abbrüchen 57600).
3. CH340 an Bord, erscheint als `/dev/ttyUSB0`. Benutzer ggf. in Gruppe
   `dialout`.
4. SSID und Passwort eintragen, hochladen, Monitor auf 115200.

In beiden Fällen sollte nach einem Reset das hier stehen:

```
neato_bridge 0.3.0
connecting to MeinWLAN
...
connected, IP 192.168.1.57
status page: http://192.168.1.57/  or http://neato.local/
FHEM: define Staubsauger NeatoLocal 192.168.1.57:23
```

Auf dem ESP8266 folgt danach der Hinweis auf den UART-Swap, und der Monitor
verstummt. Das ist Absicht, kein Absturz. Auf dem C3 bleibt er nutzbar.

## Statusseite

`http://neato.local/` zeigt Board und Pinbelegung, WLAN, IP, Laufzeit, ob FHEM
verbunden ist und die Byte-Zähler in beide Richtungen. **„Bytes from robot: 0"
heißt: die Verdrahtung stimmt nicht** – meist sind TX und RX nicht gekreuzt.

`/test` schickt einmalig `GetVersion` an den Roboter und zeigt die Antwort.
Das ist der schnellste Weg, die Lötstellen zu prüfen, bevor der Deckel wieder
zugeht. Es läuft nur, wenn gerade kein FHEM verbunden ist – sonst würde es
sich in dessen Sitzung drängeln.

Ein Trockentest ohne Roboter: die beiden Roboter-Pins mit einer Drahtbrücke
verbinden, dann kommt bei `/test` das gesendete `GetVersion` als Echo zurück.
Damit ist bewiesen, dass die UART auf den richtigen Pins liegt.

## In FHEM

```
define Staubsauger NeatoLocal neato.local:23
```

oder mit IP statt mDNS-Name. Eine bestehende USB-Definition vorher löschen –
sie hält sonst die Schnittstelle.

## Verhalten

* Ein Client zur Zeit. Eine neue Verbindung übernimmt und trennt die alte –
  ein neu gestartetes FHEM kommt so immer wieder rein.
* Bei Verbindungsabbruch, Übernahme, Leerlauf-Timeout und vor einem
  OTA-Update sendet die Brücke `TestMode Off` an den Roboter. Ein Roboter im
  Testmodus reagiert weder auf seine Tasten noch reinigt er – dort darf er
  nicht hängenbleiben.
* Fällt das WLAN aus, bootet die Brücke nicht neu, sondern wartet auf den
  Reconnect des SDK.
* Nach dem ersten Flashen geht es per OTA weiter (Hostname `neato`) –
  praktisch, wenn das Modul im Roboter verklebt ist.

## Verifizierter Build

Die CI übersetzt den Sketch bei jedem Push für **beide** Boards, den C3 mit
genau den Optionen, die die Anleitung empfiehlt.

| | ESP32-C3 | ESP8266 |
|---|---|---|
| Programm | 1 045 KB (53 % von 1,9 MB) | 291 KB (28 % von 1 MB) |
| RAM global | 41,9 KB (12 %) | 28,9 KB (36 %) |
| Besonderheit | – | IRAM zu 92 % belegt |

Die 92 % IRAM auf dem ESP8266 sind für einen ESP8266 mit WLAN normal, aber der
Grund, hier keine weiteren Bibliotheken aufzunehmen.
