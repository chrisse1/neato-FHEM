# Hardware-Anbindung

## Überblick

Der Botvac hat zwei Zugänge zu derselben seriellen Konsole (115200 8N1):

1. **USB-Port** außen am Gerät. Meldet sich am Host als CDC-ACM
   (`/dev/ttyACM0`). Null Aufwand, aber: **solange ein USB-Host angesteckt
   ist, reinigt der Roboter nicht** (Fehler 220). Das Projekt `neato-serial`
   umgeht das mit einem Relais, das USB kurz trennt – ein Workaround, der die
   Sache nicht besser macht. USB ist zum Erkunden ideal, für den Dauerbetrieb
   nicht.
2. **Interner Debug-Port** auf dem Mainboard. Kein Fehler 220, dauerhaft
   nutzbar, versorgt die Brücke gleich mit Strom. Das ist der Weg für den
   Produktivbetrieb.

## Debug-Port Botvac D3–D7

Vierpoliger Header auf dem Mainboard, Belegung von links nach rechts:

```
RX | 3.3V | TX | GND
```

Verdrahtung zum ESP (gekreuzt):

| Roboter | ESP32-C3 |
|---|---|
| RX | TX (GPIO) |
| 3.3V | 3V3 |
| TX | RX (GPIO) |
| GND | GND |

## Kartenrand-Stecker Botvac 65–85 / D75–D85

Bei den älteren Modellen sitzt vorne rechts (von vorne gesehen) je ein
Kartenrand-Stecker auf Ober- und Unterseite der Hauptplatine, beschriftet
`P7` (oben) und `P25` (unten):

* oben: Serial TX, GND, Serial RX
* unten: +3,3 V, n.c., GND

## Benötigt

* ESP32-C3 (z. B. „Super Mini“, ~3 €). **Mindestens 4 MB Flash** – die
  2-MB-Varianten reichen für OpenNeato nicht.
  Ein ESP8266 (≥ 1 MB) tut es auch, siehe unten.
* JST-XH-2,54-mm-4-Pin-Steckverbinder mit vorgecrimpten Litzen
* T10 Torx **Security** Bit zum Öffnen des Roboters
* Lötkolben

## Einbau

1. Roboter ausschalten, **Akku abklemmen**, erst dann löten.
2. Litzen so lang lassen, dass sich die Oberschale noch öffnen lässt, aber
   nicht so lang, dass sie in Mechanik oder Lüfter geraten.
3. Steckverbinder vorsehen – das ESP-Modul muss zum Flashen abnehmbar sein.
4. Modul mit doppelseitigem Klebeband auf der Oberschale fixieren, gegenüber
   dem Display.

## Stromversorgung

Der 3,3-V-Abgriff hängt hinter der Spannungsregelung des Roboters; die
Stromaufnahme eines ESP-Moduls (80–100 mA Spitze) taucht in `GetCharger` unter
`Discharge_mAH` mit auf und entlädt den Akku nicht nennenswert. Trotzdem:
Deep-Sleep oder Sendeleistung reduzieren schadet nicht, wenn der Roboter
lange außerhalb der Basis steht.

## Firmware auf dem ESP

Zwei erprobte Optionen, beide funktionieren mit diesem FHEM-Modul:

* **[OpenNeato](https://github.com/renjfk/OpenNeato)** (D3–D7) – Web-UI plus
  HTTP-Passthrough unter `/api/serial?cmd=…`.
  FHEM: `define Staubsauger NeatoLocal http://neato.local`
* **[botvac-wifi](https://github.com/sstadlberger/botvac-wifi)** (ältere
  Modelle, ESP8266) – Websocket/HTML-Interface. Sendet aus Sicherheitsgründen
  automatisch `TestMode off`, wenn ein Client die Verbindung trennt.

* **[neato_bridge](../firmware/)** (dieses Repo, ESP32-C3 *und* ESP8266) –
  dumme TCP-zu-UART-Brücke mit Statusseite, die gesamte Logik bleibt im
  FHEM-Modul. FHEM: `define Staubsauger NeatoLocal neato.local:23`

## ESP8266 statt ESP32-C3

Ein vorhandener ESP8266 (NodeMCU LoLin V3, ESP-12F o. ä.) funktioniert für
D3–D7 genauso, die Konsole ist dieselbe. Drei Punkte sind anders:

1. **Nur eine brauchbare UART.** UART0 liegt normalerweise auf GPIO1/GPIO3 –
   dort gibt das Boot-ROM beim Reset seinen Startmüll mit 74880 Baud aus, der
   sonst in der Roboterkonsole landet. `Serial.swap()` legt UART0 nach dem Boot
   auf GPIO13/GPIO15; nur diese beiden Pins gehen an den Roboter.
   Verdrahtung: Roboter TX → **D7/GPIO13**, Roboter RX → **D8/GPIO15**.
2. **Stromversorgung am 3V3-Pin, nicht an Vin/VU.** Vin läuft über den
   AMS1117-Regler des Boards. Und niemals USB und Roboter-3,3 V gleichzeitig –
   dann treiben Regler und Roboter dieselbe Schiene gegeneinander. Also: über
   USB flashen, USB abziehen, dann anschließen.
3. **Höhere Stromspitzen als beim ESP32-C3.** 220 µF Elko plus 100 nF direkt am
   Modul zwischen 3V3 und GND einplanen.

Der Formfaktor eines LoLin V3 ist für den Dauereinbau unhandlich – zum
Entwickeln und Testen ist er völlig in Ordnung, für den fertigen Aufbau ist ein
ESP32-C3 Super Mini die bessere Wahl.

## Ganz ohne Hardware testen

`tools/neato_sim.py` emuliert die Konsole über TCP. Damit lässt sich das
FHEM-Modul vollständig durchtesten, bevor der erste Lötkolben heiß wird.

Wer keine ESP-Firmware bauen will, kann den Roboter auch per USB an einen
Raspberry Pi Zero hängen und `ser2net` laufen lassen – dann greift aber wieder
die Fehler-220-Einschränkung.

## Verbindung testen

```
picocom -b 115200 /dev/ttyACM0
```

Dann `Help` eingeben. Der Roboter antwortet mit seiner vollständigen
Kommandoliste, abgeschlossen durch das Zeichen `Ctrl-Z` (0x1A). Genau dieses
Zeichen benutzt das FHEM-Modul als Antwort-Ende.
