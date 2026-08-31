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

**Wichtig:** Über USB verweigert der Roboter die Reinigung mit Fehler
`220 – Please put my Dirt Bin back in.` bzw. „unplug USB before cleaning“.
USB ist zum Erkunden und Entwickeln gut, für den Dauerbetrieb gehört die
Anbindung an den internen Debug-Port. Details in [docs/hardware.md](docs/hardware.md).

## Installation

```
# in der FHEM-Kommandozeile
"cd /opt/fhem && curl -o FHEM/74_NeatoLocal.pm https://raw.githubusercontent.com/chrisse1/neato-FHEM/main/FHEM/74_NeatoLocal.pm"
reload 74_NeatoLocal.pm

define Staubsauger NeatoLocal /dev/ttyACM0@115200
attr Staubsauger interval 60
```

Alternativ die Datei einfach nach `/opt/fhem/FHEM/` kopieren und FHEM neu starten.

Oder über den FHEM-Updatemechanismus, dann kommen Aktualisierungen mit `update` mit:

```
update add https://raw.githubusercontent.com/chrisse1/neato-FHEM/main/controls_neatolocal.txt
```

## Verwendung

```
set Staubsauger startCleaning         # Haus reinigen
set Staubsauger startCleaning spot    # Spot-Reinigung
set Staubsauger stop
set Staubsauger findMe
set Staubsauger statusRequest

get Staubsauger help                  # Kommandoliste des eigenen Roboters
get Staubsauger help Clean            # Syntax des Clean-Kommandos
get Staubsauger raw GetCharger
```

Readings: `state` (`cleaning`/`charging`/`docked`/`idle`/`error`/`disconnected`),
`batteryPercent`, `isCharging`, `isDocked`, `isCleaning`, `vacuumRPM`,
`error`, `errorCode`, `model`, `serialNumber`, `firmware`.

Die Namen folgen bewusst `74_BOTVAC.pm`, damit bestehende `notify`- und
`DOIF`-Definitionen mit minimalen Anpassungen weiterlaufen.

Zeitpläne macht FHEM ohnehin besser als die App:

```
define di_saugen DOIF ([08:30] and [Anwesenheit] eq "absent") (set Staubsauger startCleaning)
```

## Noch zu verifizieren

Für `startCleaning`, `stop` und `findMe` sind Konsolenkommandos hinterlegt.
Für `pause`, `resume` und `sendToBase` ist die Syntax der D-Serie **nicht**
belegt – das Modul erfindet hier nichts, sondern verweist auf das passende
Attribut. So findest du sie:

```
get Staubsauger help Clean
attr Staubsauger cmdSendToBase <das gefundene Kommando>
```

Siehe [docs/serial-commands.md](docs/serial-commands.md) – dort ist aufgeschlüsselt,
was aus Quellen belegt und was noch offen ist.

## Was nicht geht

* **Persistente Karten, No-Go-Linien, Zonenreinigung.** Die lagen in der
  Cloud bzw. der App und sind mit ihr verschwunden. Der Roboter navigiert
  weiterhin selbst, aber ohne gespeicherte Karte.
* **Firmware-Updates.** Gab es nur über die Cloud.

## Tests

```
perl tools/check_module.pl
```

Prüft Ladbarkeit, Transporterkennung und die Parser gegen echte Konsolenausgaben –
ohne FHEM-Installation und ohne Roboter.

## Lizenz

GPLv2, wie FHEM selbst.
