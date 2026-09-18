# neato-FHEM

FHEM-Modul zur lokalen Steuerung von Neato-Botvac-Saugrobotern – ohne Cloud.

Die Neato-Cloud wurde im 4. Quartal 2025 abgeschaltet. Damit sind die App und
alle cloudbasierten Anbindungen tot, darunter das bisherige FHEM-Modul
`74_BOTVAC.pm`. Der Roboter selbst ist es nicht: Navigation, SLAM, Reinigung
und Andocken laufen vollständig in seiner Firmware. Es fehlt nur der Auslöser,
der bisher aus der Cloud kam.

`74_NeatoLocal.pm` ersetzt diesen Auslöser. Es spricht die serielle Konsole an,
die in jedem Botvac steckt, und macht daraus ein FHEM-Gerät mit `set`, `get`
und Readings.

## Unterstützte Modelle

| Modell | Status |
|---|---|
| Botvac Connected, D3, D4, D5, D6, D7 | unterstützt, interner Debug-Port oder USB |
| Botvac 65/70e/75/80/85, D75/D80/D85, XV | unterstützt, Kartenrand-Stecker P7/P25 oder USB |
| Botvac D8, D9, D10 | **nicht** unterstützt: anderes Board, serieller Port ist passwortgeschützt |

Entwickelt und geprüft an einem **BotVac D6 Connected mit Software 4.5.3.189**.
Der vollständige Mitschnitt seiner Konsole liegt in
[`docs/reference-dump-botvac-d6.txt`](docs/reference-dump-botvac-d6.txt) und
dient den Tests als Grundlage.

## Anbindung

Drei Transportwege, alle vom selben Modul bedient:

| Transport | Angabe im `define` | Einsatz |
|---|---|---|
| seriell | `/dev/ttyACM0@115200` | USB-Port des Roboters, gut zum Erkunden |
| TCP | `192.168.1.42:23` | WLAN-Brücke im Roboter |
| HTTP | `http://neato.local` | [OpenNeato](https://github.com/renjfk/OpenNeato) auf einem ESP32-C3 |

Für die TCP-Variante liegt in [`firmware/`](firmware/) eine passende
Brücken-Firmware: ein Sketch für ESP32-C3 und ESP8266, der im Roboter verbaut
wird und dessen Konsole ins Netz bringt. Verdrahtung, Stromversorgung und eine
Schritt-für-Schritt-Flash-Anleitung stehen in
[docs/hardware.md](docs/hardware.md) und
[docs/flashing-esp32c3.md](docs/flashing-esp32c3.md).

**Hinweis zu USB:** Manche Firmware verweigert die Reinigung, solange ein
USB-Host angesteckt ist (Fehler 220). Für den Dauerbetrieb ist die Anbindung
an den internen Debug-Port vorgesehen; USB eignet sich zum Erkunden und für
die Diagnose.

## Installation

### Über den FHEM-Updatemechanismus

```
update add https://raw.githubusercontent.com/chrisse1/neato-FHEM/main/controls_neatolocal.txt
update
shutdown restart
```

Danach genügt ein `update`, um auf den neuesten Stand zu kommen; `update check`
zeigt vorher, was sich ändern würde. `update delete <url>` entfernt die Quelle
wieder. FHEM schreibt dabei direkt nach `/opt/fhem/FHEM/`, der Benutzer, unter
dem FHEM läuft, braucht dort Schreibrecht.

### Von Hand

```sh
sudo cp 74_NeatoLocal.pm /opt/fhem/FHEM/
sudo chown fhem:dialout /opt/fhem/FHEM/74_NeatoLocal.pm
sudo chmod 644 /opt/fhem/FHEM/74_NeatoLocal.pm
```

Dann in der FHEM-Kommandozeile:

```
reload 74_NeatoLocal.pm
define Staubsauger NeatoLocal 192.168.1.42:23
attr Staubsauger interval 60
save
```

`reload` ist nicht optional: FHEM liest das Verzeichnis `FHEM/` beim Start ein
und kennt eine danach hinzugekommene Datei nicht – `define` scheitert sonst mit
*Cannot load module NeatoLocal*. Ein FHEM-Neustart tut es genauso. Ohne `save`
ist die Definition nach dem nächsten Neustart wieder weg.

### Rechte am seriellen Port

Nur für den seriellen Weg nötig, bei der WLAN-Brücke entfällt er. Die Rechte an
der Moduldatei haben nichts mit dem Zugriff auf `/dev/ttyACM0` zu tun: der Port
gehört üblicherweise `root:dialout`, also muss der Benutzer, unter dem FHEM
läuft, in dieser Gruppe sein.

```sh
id fhem                          # steht dialout dabei?
sudo usermod -aG dialout fhem    # falls nicht
sudo systemctl restart fhem      # Gruppenwechsel wirkt erst nach Neustart
```

Es kann immer nur ein Prozess den Port offen haben – ein laufendes
`dump_robot.py` blockiert FHEM und umgekehrt.

## set

| Kommando | Wirkung |
|---|---|
| `startCleaning [house\|spot\|explore\|persistent]` | Hausreinigung (Vorgabe), Spot-Reinigung, Erkundungsfahrt zum Kartenaufbau, Reinigung auf der gespeicherten Karte |
| `stop` | Reinigung beenden |
| `pause` / `resume` | Reinigung unterbrechen und fortsetzen |
| `sendToBase` | zurück zur Basis |
| `findMe` | Tonsignal zum Auffinden |
| `clearError` | gemeldeten Fehler quittieren |
| `navigationMode Normal\|Gentle\|Deep\|Quick` | Reinigungsmodus |
| `ecoMode on\|off` | leiser, geringere Saugleistung |
| `intenseClean on\|off` | Intensivreinigung |
| `binFullDetect on\|off` | Erkennung des vollen Staubbehälters |
| `syncTime` | Uhr des Zeitgebers im Roboter aus FHEM stellen |
| `button <name>` | beliebigen Tastendruck simulieren |
| `statusRequest` | Zustand sofort abfragen |
| `reconnect` | Verbindung neu aufbauen |
| `testMode on\|off` | Diagnosemodus der Konsole, siehe unten |
| `raw <Kommando>` | beliebiges Konsolenkommando senden |

**`testMode`** schaltet den Roboter in den Diagnosemodus. Dort reagiert er
weder auf seine Tasten noch reinigt er. Das Modul aktiviert ihn nie von selbst
und sendet bei Shutdown, Löschen und `disable` immer `TestMode Off`.

## get

| Abfrage | Inhalt |
|---|---|
| `help [Kommando]` | Kommandoliste des Roboters bzw. Hilfe zu einem Kommando |
| `version` | Modell, Seriennummer, Firmware |
| `state` | Zustand laut Roboter |
| `charger` | Akku- und Ladewerte |
| `battery` | Messwerte der Smart Battery |
| `warranty` | Lebensdauerzähler |
| `settings` | Benutzereinstellungen |
| `motors`, `sensors`, `usage`, `wifiStatus` | Rohdaten |
| `raw <Kommando>` | beliebiges Konsolenkommando |

## Readings

### Zustand

`state` kennt `cleaning`, `paused`, `suspended`, `docking`, `charging`,
`docked`, `idle`, `error`, `unreachable` und `disconnected`.

* **`suspended`** – der Roboter hat die Reinigung selbst unterbrochen, in aller
  Regel wegen leerem Akku, und will sie nach dem Laden fortsetzen. Steht dabei
  `isDocked 0`, hat er die Basis nicht mehr erreicht.
* **`unreachable`** – die Verbindung steht, aber der Roboter antwortet nicht:
  er schläft, oder die Brücke ist nicht mit ihm verdrahtet. Die Abfrage geht
  dann schrittweise bis auf das 16-fache Intervall zurück, höchstens eine
  Stunde, statt Zeitüberschreitungen ins Log zu schreiben. Die erste Antwort
  setzt alles zurück.

`uiState` und `robotState` geben den Zustand unverändert so wieder, wie der
Roboter ihn meldet.

### Akku

| Reading | Bedeutung |
|---|---|
| `batteryPercent` | Ladestand in Prozent |
| `batteryHealth` | Restkapazität in Prozent der Nennkapazität |
| `batteryCapacityFull`, `batteryCapacityDesign` | aktuelle und ursprüngliche Kapazität in mAh |
| `batteryCycles`, `cleaningHours` | Lebensdauerzähler |
| `batteryVoltage`, `batteryTemperature`, `batteryState` | Spannung, Temperatur, ok/low |
| `isCharging`, `isDocked` | Lade- und Dockzustand |

`batteryHealth` kommt aus der Messelektronik im Akku selbst und sagt zuverlässig
voraus, wann ein Roboter unterwegs liegenbleibt. Unterhalb von etwa 50 % schafft
er es zunehmend nicht mehr zurück zur Basis, obwohl die Ladeanzeige bis kurz
davor brauchbar aussieht:

```
define di_akku DOIF ([Staubsauger:batteryHealth] < 50) (set Nachricht Akku schwach)
```

### Fehler und Hinweise

`error`/`errorCode` und `alert`/`alertCode` sind getrennt: ein voller
Staubbehälter (Alert 248) ist kein Fehler und setzt das Gerät nicht in den
Fehlerzustand, ein fehlender Behälter (Error 249) schon. Code 200
(`UI_ALERT_INVALID`) bedeutet „nichts zu melden“.

### Einstellungen und Geräteangaben

`ecoMode`, `intenseClean`, `binFullDetect`, `wallFollower`, `clickSounds`,
`melodySounds`, `warningSounds`, `led`, `wifiEnabled`, `language`,
`filterChangeTime`, `brushChangeTime`, `dirtBinInterval`, `scheduleEnabled`,
`scheduledCleanings` – beim Verbinden und nach jeder Änderung gelesen.

`model`, `serialNumber`, `firmware`, `ldsSoftware`, `hardware`, `commandApi`.

`navigationMode` ist eine Ausnahme: die Konsole kennt kein Kommando, ihn
auszulesen. Das Reading hält deshalb den zuletzt gesetzten Wert. Weil der
Roboter den Modus nicht über Läufe hinweg behält, sendet das Modul ihn vor
jeder Hausreinigung erneut.

Die Reading-Namen folgen bewusst denen von `74_BOTVAC.pm`, damit bestehende
`notify`- und `DOIF`-Definitionen mit geringen Anpassungen weiterlaufen.

## Attribute

| Attribut | Vorgabe | Bedeutung |
|---|---|---|
| `interval` | 60 | Abfrageintervall in Sekunden |
| `timeout` | 10 | wie lange auf eine Antwort gewartet wird |
| `connectTimeout` | 2 | Obergrenze für einen Verbindungsversuch |
| `pollState` | 1 | `GetState` mitabfragen |
| `pollErrors` | 1 | `GetErr` mitabfragen |
| `pollMotors` | 0 | `GetMotors` mitabfragen |
| `pollSettings` | 0 | Benutzereinstellungen bei jedem Durchlauf mitlesen |
| `useSetEvent` | 1 | die Event-Schnittstelle nutzen, wenn verfügbar |
| `cmdCleanHouse`, `cmdCleanSpot`, `cmdCleanExplore`, `cmdCleanPersistent`, `cmdCleanStop`, `cmdCleanPause`, `cmdCleanResume`, `cmdSendToBase`, `cmdFindMe` | – | Konsolenkommando je set-Kommando überschreiben |
| `httpPath`, `httpMethod` | `/api/serial`, POST | nur für den HTTP-Transport |
| `disable` | 0 | Verbindung schließen und Abfrage anhalten |

## Kommandosatz

Die `Help`-Ausgabe des Roboters ist nicht vollständig. Pause, Fortsetzen und
Rückkehr zur Basis laufen über `SetEvent`, die authentifizierte
Event-Schnittstelle, über die früher die Cloud den Roboter gesteuert hat und
die in keiner Kommandoliste auftaucht. Ihr Schlüssel wird aus der MAC-Adresse
berechnet, die `GetVersion` mitliefert.

| set-Kommando | Weg |
|---|---|
| `startCleaning`, `stop` | `SetEvent`, sonst `Clean House` / `Clean Stop` |
| `pause` / `resume` | `SetEvent`, ohne Schlüssel `SetButton start` als Umschalter |
| `sendToBase` | **nur** `SetEvent` – die dokumentierten Kommandos bieten dafür nichts |
| `findMe` | `PlaySound SoundID 20` |

Das Reading `commandApi` zeigt, ob die Schnittstelle freigeschaltet ist
(`setEvent` oder `legacy`). `attr <dev> useSetEvent 0` erzwingt die
dokumentierten Kommandos.

Gefunden und entschlüsselt hat die Event-Schnittstelle, `GetState` und die
übrigen undokumentierten Kommandos das Projekt
[OpenNeato](https://github.com/renjfk/OpenNeato) (MIT, © 2026 Soner Köksal).
Dieses Modul enthält eine eigenständige Perl-Umsetzung, die gegen deren
C++-Original auf bekannten Werten geprüft ist. Alle Einzelheiten stehen in
[docs/serial-commands.md](docs/serial-commands.md).

## Was nicht geht

* **No-Go-Linien und Zonenreinigung.** Sie wurden in der App verwaltet und sind
  mit ihr verschwunden. Die persistente Karte selbst lebt im Roboter:
  `startCleaning explore` baut sie auf, `startCleaning persistent` nutzt sie.
* **Firmware-Updates des Roboters.** Gab es nur über die Cloud.
* **Die Karte auslesen.** Die Konsole bietet dafür kein Kommando.

## Werkzeuge

### Konsole eines Roboters auslesen

`tools/dump_robot.py` fragt den Roboter nach seiner Kommandoliste, holt zu jedem
genannten Kommando den Hilfetext und dazu die Ausgaben der harmlosen `Get*`-
Kommandos. Das Ergebnis dokumentiert, was die jeweilige Firmware versteht.

```
python3 tools/dump_robot.py --device /dev/ttyACM0
python3 tools/dump_robot.py --tcp 192.168.1.42:23
python3 tools/dump_robot.py --device /dev/ttyACM0 --diagnose
```

Das Skript liest nur: es sendet ausschließlich `Help` und `Get*`. Kein
`TestMode`, keine Motorkommandos, keine Einstellungsänderungen. Seriennummern
werden maskiert, damit sich ein Dump gefahrlos weitergeben lässt
(`--no-redact` schaltet das ab). Es braucht nur ein normales Python 3; die
serielle Schnittstelle wird über `termios` aus der Standardbibliothek
konfiguriert, pyserial ist nicht nötig.

`--diagnose` prüft Gerät, Rechte und belegende Prozesse, meldet die USB-Kennung,
hört fünf Sekunden passiv mit und probiert alle drei Zeilenenden durch, jeweils
mit Hexdump. Die häufigsten Ursachen für eine stumme Konsole sind, in dieser
Reihenfolge: ein schlafender Roboter, der falsche Port, ein belegter Port und
ein Ladekabel ohne Datenleitungen.

### Ohne Roboter testen

`tools/neato_sim.py` emuliert die Konsole eines Botvac über TCP, mit
Kommando-Echo, `Ctrl-Z`-Terminator, den CSV-Ausgaben des echten Geräts und
plausiblem Verhalten: der Akku entlädt sich beim Saugen und lädt in der Basis.

```
python3 tools/neato_sim.py
```

```
define Staubsauger NeatoLocal 127.0.0.1:8888
```

Mit `--usb` verweigert der Simulator die Reinigung mit Fehler 220 wie ein
Roboter mit angestecktem USB-Host.

## Fehlersuche

**FHEM bleibt kurz stehen.** FHEM baut TCP-Verbindungen synchron auf; solange
ein Verbindungsversuch läuft, steht der ganze Prozess. Die Brücke wird vom
Roboter versorgt und ist weg, sobald er aus ist. Das Modul begrenzt den Versuch
auf 2 Sekunden, `connectTimeout` senkt das weiter. `apptime` in der
FHEM-Kommandozeile weist es nach: erscheint dort `NeatoLocal_Ready` oder
`DevIo_OpenDev` mit langer Laufzeit, ist es der Verbindungsaufbau.

**Der Roboter antwortet nicht.** `state` steht auf `unreachable`: Roboter
wecken, Verdrahtung der Brücke prüfen (`http://neato.local/` zeigt die
Byte-Zähler in beide Richtungen), oder `--diagnose` am USB-Port laufen lassen.

**Ein Kommando bleibt wirkungslos.** `get <dev> help Clean` zeigt, was die
jeweilige Firmware versteht; über die `cmd*`-Attribute lässt sich jedes
Kommando anpassen.

## Tests

```
perl tools/check_module.pl    # Modul: Laden, Transporte, Parser, Zustandslogik
python3 tools/check_sim.py    # Simulator: Protokoll und Zustandsübergänge
python3 tools/check_dump.py   # Dump-Werkzeug, seriell über ein PTY und über TCP
```

Alle drei laufen ohne FHEM-Installation und ohne Roboter. Die Testdaten sind
wörtliche Konsolenausgaben eines BotVac D6. Die CI führt sie bei jedem Push aus
und übersetzt zusätzlich die Brücken-Firmware für ESP32-C3 und ESP8266.

## Lizenz

GPLv2, wie FHEM selbst.
