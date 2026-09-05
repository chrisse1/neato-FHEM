# neato-FHEM

FHEM-Modul zur **lokalen** Steuerung von Neato-Botvac-Saugrobotern – ohne Cloud.

Die Neato-Cloud wurde im 4. Quartal 2025 abgeschaltet. Damit sind die App und
alle cloudbasierten Anbindungen (u. a. das FHEM-Modul `74_BOTVAC.pm`) tot.
Der Roboter selbst ist es nicht: Navigation, SLAM, Reinigung und Andocken
laufen komplett in seiner Firmware. Es fehlt nur der *Auslöser*, der bisher aus
der Cloud kam.

Dieses Projekt ersetzt den Auslöser – nicht die Firmware. Der Roboter hat eine
eingebaute serielle Konsole, über die sich Reinigung starten/stoppen und Akku-,
Lade- und Fehlerstatus auslesen lassen. Genau daran hängt sich `74_NeatoLocal.pm`.

## Warum keine echte Custom Firmware?

Die Botvacs sind kein Linux-Gerät wie die Roborocks, bei denen Valetudo ansetzt,
sondern ein RTOS auf einem Cortex-M. Eine eigene Firmware hieße: Lidar-Treiber,
SLAM, Pfadplanung, Wandverfolgung, Andocken und Motorregelung neu schreiben –
für ein Ergebnis, das schlechter wäre als das, was bereits im Roboter steckt.
Der serielle Weg liefert 90 % des Nutzens für 1 % des Aufwands.

## Unterstützte Modelle

| Modell | Status |
|---|---|
| Botvac Connected, D3, D4, D5, D6, D7 | unterstützt (interner Debug-Port + USB) |
| Botvac 65/70e/75/80/85, D75/D80/D85, XV | unterstützt (Kartenrand-Stecker P7/P25 + USB) |
| Botvac D8, D9, D10 | **nicht** unterstützt – anderes Board, serieller Port ist passwortgeschützt |

## Anbindung

Drei Transportwege, alle vom selben Modul bedient:

| Transport | Define | Einsatz |
|---|---|---|
| USB / seriell | `/dev/ttyACM0@115200` | Test und Entwicklung, Roboter hängt am Kabel |
| TCP | `192.168.1.42:23` | ESP-WLAN-Brücke (botvac-wifi) oder `ser2net` |
| HTTP | `http://neato.local` | [OpenNeato](https://github.com/renjfk/OpenNeato) auf einem ESP32-C3 |

Für die TCP-Variante liegt in [`firmware/`](firmware/) eine passende Brücken-Firmware
(`neato_bridge.ino`) – ein Sketch für ESP32-C3 und ESP8266.

**Wichtig:** Über USB verweigert der Roboter die Reinigung mit Fehler
`220 – Please put my Dirt Bin back in.` bzw. „unplug USB before cleaning“.
USB ist zum Erkunden und Entwickeln gut, für den Dauerbetrieb gehört die
Anbindung an den internen Debug-Port. Details in [docs/hardware.md](docs/hardware.md).

## Installation

Auf der Kommandozeile des FHEM-Rechners:

```sh
sudo cp 74_NeatoLocal.pm /opt/fhem/FHEM/
sudo chown fhem:dialout /opt/fhem/FHEM/74_NeatoLocal.pm
sudo chmod 644 /opt/fhem/FHEM/74_NeatoLocal.pm
```

Dann in der FHEM-Kommandozeile:

```
reload 74_NeatoLocal.pm
define Staubsauger NeatoLocal /dev/ttyACM0@115200
attr Staubsauger interval 60
save
```

`reload` ist nicht optional: FHEM liest das Verzeichnis `FHEM/` beim Start
ein. Eine danach hinzugekommene Datei kennt es nicht, und `define` scheitert
mit *Cannot load module NeatoLocal*. Ein FHEM-Neustart tut es genauso.
Und ohne `save` ist die Definition nach dem nächsten Neustart wieder weg.

### Rechte am seriellen Port

Der Punkt, an dem es gern klemmt: **die Rechte an der Moduldatei haben nichts
mit dem Zugriff auf `/dev/ttyACM0` zu tun.** Der Port gehört üblicherweise
`root:dialout`, also muss der Benutzer, unter dem FHEM läuft, in der Gruppe
`dialout` sein:

```sh
id fhem                          # steht dialout dabei?
sudo usermod -aG dialout fhem    # falls nicht
sudo systemctl restart fhem      # Gruppenwechsel wirkt erst nach Neustart
```

Beim Weg über die WLAN-Brücke (`define ... <ip>:23`) entfällt das komplett –
dort spricht FHEM nur über das Netz.

Außerdem: Es kann immer nur ein Prozess den Port offen haben. Ein noch
laufendes `dump_robot.py` blockiert FHEM und umgekehrt.

### Über den FHEM-Updatemechanismus

Solange das Repository öffentlich ist, kommen Aktualisierungen so mit `update`
mit:

```
update add https://raw.githubusercontent.com/chrisse1/neato-FHEM/main/controls_neatolocal.txt
```

## Verwendung

```
set Staubsauger startCleaning              # Haus reinigen
set Staubsauger startCleaning spot         # Spot-Reinigung
set Staubsauger startCleaning explore      # Erkundungsfahrt (Karte aufbauen)
set Staubsauger startCleaning persistent   # Reinigung auf gespeicherter Karte
set Staubsauger stop
set Staubsauger pause                      # bzw. resume
set Staubsauger sendToBase
set Staubsauger findMe
set Staubsauger clearError
set Staubsauger navigationMode Deep
set Staubsauger syncTime                   # Uhr des Roboters stellen
set Staubsauger statusRequest

get Staubsauger help                  # Kommandoliste des eigenen Roboters
get Staubsauger help Clean            # Syntax des Clean-Kommandos
get Staubsauger raw GetCharger
```

Readings: `state` (`cleaning`/`charging`/`docked`/`idle`/`error`/`disconnected`),
`batteryPercent`, `isCharging`, `isDocked`, `isCleaning`, `vacuumRPM`,
`error`/`errorCode`, `alert`/`alertCode`, `usbConnected`, `model`,
`serialNumber`, `firmware`, `ldsSoftware`.

`GetErr` trennt Fehler und Hinweise: ein voller Staubbehälter (Alert 248) ist
kein Fehler und setzt das Gerät nicht in den Fehlerzustand – ein fehlender
Behälter (Error 249) schon.

Die Namen folgen bewusst `74_BOTVAC.pm`, damit bestehende `notify`- und
`DOIF`-Definitionen mit minimalen Anpassungen weiterlaufen.

Zeitpläne macht FHEM ohnehin besser als die App:

```
define di_saugen DOIF ([08:30] and [Anwesenheit] eq "absent") (set Staubsauger startCleaning)
```

## Verifizierter Kommandosatz

Die Vorgaben stammen aus dem Mitschnitt eines **BotVac D6 Connected,
Software 4.5.3.189** – der vollständige Dump liegt in
[`docs/reference-dump-botvac-d6.txt`](docs/reference-dump-botvac-d6.txt),
die Auswertung in [docs/serial-commands.md](docs/serial-commands.md).

Pause, Fortsetzen und Rückkehr zur Basis gibt es im `Clean`-Kommando nicht;
der Roboter bietet dafür `SetButton`:

| set-Kommando | Konsolenkommando |
|---|---|
| `pause` / `resume` | `SetButton start` (Umschalter) |
| `sendToBase` | `SetButton IRhome` |
| `findMe` | `PlaySound SoundID 20` |

Jedes davon lässt sich per Attribut überschreiben, falls deine Firmware
anders heißt.

## Was nicht geht

* **No-Go-Linien und Zonenreinigung.** Die wurden in der App verwaltet und
  sind mit ihr weg. Die *persistente Karte* selbst lebt im Roboter:
  `Clean Explore` baut sie auf, `Clean Persistent` nutzt sie.
* **Firmware-Updates.** Gab es nur über die Cloud.

## Ohne Roboter testen

`tools/neato_sim.py` emuliert die Konsole eines Botvac über TCP – inklusive
Kommando-Echo, `Ctrl-Z`-Terminator, CSV-Ausgaben und plausiblem Verhalten
(Akku entlädt sich beim Saugen, lädt in der Basis):

```
python3 tools/neato_sim.py
```

```
define Staubsauger NeatoLocal 127.0.0.1:8888
set Staubsauger startCleaning
```

Mit `--usb` verhält sich der Simulator wie ein Roboter mit angestecktem
USB-Host und verweigert die Reinigung mit Fehler 220 – damit lässt sich der
Fehlerpfad testen, ohne ihn provozieren zu müssen.

## Konsole des eigenen Roboters auslesen

`tools/dump_robot.py` fragt den Roboter nach seiner Kommandoliste, holt zu jedem
genannten Kommando den Hilfetext und dazu die Ausgaben der harmlosen `Get*`-
Kommandos. Heraus kommt eine Datei, die genau dokumentiert, was *deine* Firmware
versteht – die Grundlage, um die noch offenen Kommandos zu ergänzen.

```
python3 tools/dump_robot.py --device /dev/ttyACM0
python3 tools/dump_robot.py --tcp 192.168.1.42:23     # über die WLAN-Brücke
```

Das Skript **liest nur**: es sendet ausschließlich `Help` und `Get*`. Kein
`TestMode`, keine Motorkommandos, keine Einstellungsänderungen. Seriennummern
werden standardmäßig maskiert, damit sich der Dump gefahrlos weitergeben lässt
(`--no-redact` schaltet das ab). Es braucht nur ein normales Python 3 –
die serielle Schnittstelle wird über `termios` aus der Standardbibliothek
konfiguriert, pyserial ist nicht nötig.

Solange FHEM die Schnittstelle geöffnet hat, ist sie belegt: erst den Dump
ziehen, dann das Gerät in FHEM definieren.

### Wenn der Roboter nicht antwortet

```
python3 tools/dump_robot.py --device /dev/ttyACM0 --diagnose
```

Der Diagnosemodus prüft Gerät, Rechte und belegende Prozesse, meldet die
USB-Kennung, hört fünf Sekunden passiv mit und probiert alle drei Zeilenenden
durch – mit Hexdump dessen, was tatsächlich ankommt. Das Ergebnis landet in
`neato-diagnose.txt`.

Die häufigsten Ursachen, in dieser Reihenfolge:

1. **Der Roboter schläft.** Der USB-Port ist dann zwar da, die Konsole aber
   stumm. Eine Taste drücken, von der Basis nehmen und zurückstellen, dann
   sofort erneut versuchen.
2. **Falscher Port.** Der Diagnosemodus listet alle vorhandenen
   `ttyACM*`/`ttyUSB*` auf.
3. **Port belegt**, meist von FHEM selbst.
4. **Ladekabel statt Datenkabel.**

## Tests

```
perl tools/check_module.pl    # Modul: Laden, Transporterkennung, Parser
python3 tools/check_sim.py    # Simulator: Protokoll und Zustandsübergänge
python3 tools/check_dump.py   # Dump-Werkzeug, seriell über ein PTY und über TCP
```

Alle drei laufen ohne FHEM-Installation und ohne Roboter.

## Lizenz

GPLv2, wie FHEM selbst.
