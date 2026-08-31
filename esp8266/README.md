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

## Bauen und flashen

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
