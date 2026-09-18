# ESP32-C3 flashen

Schritt für Schritt für `firmware/neato_bridge`. Alle Board-Optionen sind aus
der `boards.txt` des ESP32-Cores verifiziert, nicht aus dem Gedächtnis.

**Der Roboter ist während des gesamten Flash-Vorgangs nicht angeschlossen.**

## 1. Core installieren

Arduino IDE → *Datei → Einstellungen → Zusätzliche Boardverwalter-URLs*:

```
https://espressif.github.io/arduino-esp32/package_esp32_index.json
```

Dann *Werkzeuge → Board → Boardverwalter* → „esp32 by Espressif Systems"
installieren.

## 2. Board auswählen

Zwei Möglichkeiten, je nachdem was du hast:

### a) Du hast einen „Super Mini"

Board: **Nologo ESP32C3 Super Mini**

Dieser Eintrag hat `cdc_on_boot=1` fest eingebaut – USB CDC ist immer an, du
musst nichts umstellen. Das ist der bequemere Weg.

### b) Beliebiges anderes C3-Board

Board: **ESP32C3 Dev Module**, dann diese Einstellungen:

| Menüpunkt | Wert | Warum |
|---|---|---|
| **USB CDC On Boot** | **Enabled** | Vorgabe ist *Disabled*. Ohne das bleibt der serielle Monitor stumm und `Serial` landet auf GPIO20/21. |
| **Partition Scheme** | **Minimal SPIFFS (1.9MB APP with OTA/128KB SPIFFS)** | siehe unten |
| Flash Size | 4MB (32Mb) | |
| Upload Speed | 921600 | bei Abbrüchen 115200 |
| JTAG Adapter | Disabled | |

### Warum nicht das Standard-Partitionsschema

Der Sketch belegt **1 045 321 Byte**. In der Vorgabe „Default 4MB with spiffs"
stehen dafür 1 310 720 Byte zur Verfügung – das sind **79 %**, und OTA-Updates
brauchen eine zweite App-Partition derselben Größe. Es geht, aber der Puffer
ist dünn.

„Minimal SPIFFS" gibt der App 1 966 080 Byte, damit liegt die Auslastung bei
53 %. Das Dateisystem schrumpft dabei auf 128 KB – die Brücke benutzt keines,
also kostet das nichts.

Beide Schemata haben zwei App-Partitionen und können OTA. Was **nicht** geht,
sind die Varianten mit „No OTA" im Namen.

**USB CDC On Boot ist der Punkt, an dem es sonst schiefgeht.** Wenn der
serielle Monitor leer bleibt, ist fast immer das die Ursache.

## 3. WLAN eintragen

Oben in `firmware/neato_bridge/neato_bridge.ino`:

```cpp
#define WIFI_SSID "MeinWLAN"
#define WIFI_PSK  "geheim"
```

Optional, falls du andere Pins verwenden willst:

```cpp
#define ROBOT_RX_PIN 4    // Roboter TX kommt hier an
#define ROBOT_TX_PIN 5    // geht an Roboter RX
```

## 4. Port und Upload

Der C3 hat natives USB, kein Adapterchip. Unter Linux meldet er sich als
`/dev/ttyACM0`:

```
ls -l /dev/ttyACM*
```

Bei „Permission denied": `sudo usermod -aG dialout $USER`, danach neu anmelden.

Dann *Hochladen*. Wenn der Upload nicht startet oder mit
`No serial data received` abbricht, den Bootmodus von Hand erzwingen:

1. **BOOT** gedrückt halten
2. kurz **RESET** drücken (oder bei gedrückter BOOT-Taste das USB-Kabel
   einstecken)
3. **BOOT** loslassen
4. Upload starten

Manche Super Minis haben nur eine BOOT-Taste – dann Kabel ziehen, BOOT halten,
Kabel einstecken, BOOT loslassen.

Nach dem Upload verschwindet der Port kurz und kommt neu – in der IDE
gegebenenfalls neu auswählen, bevor du den Monitor öffnest.

## 5. Prüfen

Seriellen Monitor auf **115200** öffnen, RESET drücken:

```
neato_bridge 0.3.0
connecting to MeinWLAN
...
connected, IP 192.168.1.57
status page: http://192.168.1.57/  or http://neato.local/
FHEM: define Staubsauger NeatoLocal 192.168.1.57:23
```

Anders als beim ESP8266 bleibt der Monitor beim C3 dauerhaft nutzbar – die
UART zum Roboter ist eine andere.

Bleibt der Monitor leer: USB CDC On Boot prüfen (Schritt 2).
Bleibt das WLAN weg: SSID und Passwort prüfen; der C3 kann nur 2,4 GHz.

## 6. Trockentest ohne Roboter

Statusseite `http://neato.local/` aufrufen. Dann **GPIO4 und GPIO5 mit einer
Drahtbrücke verbinden** und `/test` anklicken: das gesendete `GetVersion` kommt
als Echo zurück. Damit ist bewiesen, dass die UART auf den richtigen Pins liegt
– bevor du am Roboter lötest.

Drahtbrücke wieder entfernen.

## 7. Einbau

Akku abklemmen. Debug-Header im Roboter ist `RX | 3.3V | TX | GND` (von links),
TX und RX werden **gekreuzt**:

| Roboter | ESP32-C3 |
|---|---|
| TX | GPIO4 |
| RX | GPIO5 |
| GND | GND |
| 3.3V | **3V3** (nicht 5V) |

220 µF Elko plus 100 nF direkt am Modul zwischen 3V3 und GND.

**USB und Roboterstrom nie gleichzeitig.** Ab jetzt läuft alles über OTA
(Hostname `neato`) und die Statusseite.

## 8. Verdrahtung prüfen, bevor der Deckel zugeht

`/test` erneut aufrufen – jetzt sollte die echte `GetVersion`-Ausgabe des
Roboters erscheinen. Auf der Statusseite heißt **„Bytes from robot: 0", dass
TX und RX nicht gekreuzt sind**.

## 9. FHEM umstellen

Die bestehende USB-Definition löschen, sonst hält sie die Schnittstelle:

```
delete Staubsauger
define Staubsauger NeatoLocal 192.168.1.57:23
attr Staubsauger interval 60
```

## Mit arduino-cli statt IDE

```sh
arduino-cli core update-index \
  --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core install esp32:esp32 \
  --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json

arduino-cli compile \
  --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc,PartitionScheme=min_spiffs,FlashSize=4M \
  firmware/neato_bridge

arduino-cli upload -p /dev/ttyACM0 \
  --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc,PartitionScheme=min_spiffs,FlashSize=4M \
  firmware/neato_bridge

arduino-cli monitor -p /dev/ttyACM0 -c baudrate=115200
```

SSID und Passwort lassen sich auch beim Übersetzen setzen, ohne die Datei zu
ändern:

```sh
arduino-cli compile \
  --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc,PartitionScheme=min_spiffs,FlashSize=4M \
  --build-property 'compiler.cpp.extra_flags=-DWIFI_SSID="MeinWLAN" -DWIFI_PSK="geheim"' \
  firmware/neato_bridge
```

## Wenn der Server dem Board dazwischenfunkt

Am USB eines Linux-Servers hat das Board Gesellschaft: Jeder Prozess, der
`/dev/ttyACM*` öffnet, kann den C3 zurücksetzen. `ModemManager` tut genau das –
er probiert neue ttyACM-Geräte mit AT-Kommandos an. Ein Board, das sich
verbindet und kurz darauf wieder verschwindet, sieht danach aus.

Nachsehen, ob er läuft:

```sh
systemctl status ModemManager
```

Das Board von ihm ausnehmen, statt den Dienst abzuschalten – die Kennung
stammt aus `lsusb` (Espressif mit nativem USB meldet sich als `303a:1001`):

```
# /etc/udev/rules.d/99-neato-bridge.rules
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1001", ENV{ID_MM_DEVICE_IGNORE}="1"
```

```sh
sudo udevadm control --reload-rules
```

Ob das Board tatsächlich neu gestartet ist, sagt es selbst: `info` nennt
`uptime s` und `boot`. Steigt die Laufzeit durch und steht `link drops` auf 0,
hat es nie ausgesetzt – dann liegt der Ausfall woanders. Springt die Laufzeit
zurück, hat es neu gestartet, und `boot` nennt den Grund: `external reset` und
`software restart` kommen von außen, `brownout` von der Stromversorgung, `crash`
von der Firmware.
