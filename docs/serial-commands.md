# Serielle Konsole des Botvac

Verbindung: 115200 Baud, 8N1. Jedes Kommando wird mit `\n` abgeschlossen, der
Roboter **echot das Kommando** und beendet seine Antwort mit `Ctrl-Z` (0x1A).
Ausgaben sind CSV-artig, erste Spalte Schlüssel, zweite Spalte Wert.

Maßgeblich ist immer die Hilfe des eigenen Roboters:

```
get <device> help
get <device> help Clean
```

## TestMode – bitte lesen

`TestMode On` schaltet den Roboter in den Diagnosemodus. Dort reagiert er
**nicht mehr auf seine Tasten und reinigt nicht**, dafür werden Kommandos wie
`SetMotor` oder Teile der Sensorik erst verfügbar.

Deshalb:

* Das Modul schaltet TestMode **niemals von selbst** ein. Es pollt
  ausschließlich Kommandos, die ohne TestMode funktionieren.
* `set <device> testMode on` ist bewusst explizit.
* Bei Shutdown, Löschen und `attr disable 1` sendet das Modul immer
  `TestMode Off`, damit der Roboter nicht taub zurückbleibt.

## Belegte Kommandos

Verifiziert an einem **BotVac D6 Connected, Software 4.5.3.189**. Der
vollständige Mitschnitt liegt in
[`reference-dump-botvac-d6.txt`](reference-dump-botvac-d6.txt).

| Kommando | Zweck | Ausgewertete Felder |
|---|---|---|
| `GetCharger` | Akku- und Ladestatus | `FuelPercent`, `ChargingActive`, `ExtPwrPresent`, `BatteryOverTemp`, `VBattV` |
| `GetErr` | Fehler, Alarm, USB-Status | Abschnitte `Error`, `Alert`, `USB state` |
| `GetErr Clear` | Fehler quittieren | – |
| `GetMotors` | Motorzustand | `Vacuum_RPM` > 0 ⇒ der Roboter saugt |
| `GetVersion` | Gerätedaten | `Model`, `Serial Number`, `Software`, `LDS Software`, `MainBoard Version` |
| `GetAnalogSensors` | Analogsensorik | roh (`get sensors`) |
| `GetUserSettings` | Einstellungen und Zeitplan | roh (`get settings`) |
| `GetUsage` | Verbrauchszähler | roh (`get usage`) |
| `Help [cmd]` | Kommandoliste des Roboters | roh |

### Clean

```
Clean [Explore|House|Spot|Stop] [Persistent] [Width n] [Height n] [AutoCycle n]
```

* `Clean House` – Hausreinigung (Standard)
* `Clean Spot` – Spot-Reinigung, optional `Width`/`Height` in cm (100–400)
* `Clean Explore` – Erkundungsfahrt zum Kartenaufbau
* `Clean Persistent` – Reinigung anhand der gespeicherten Karte
* `Clean Stop` – Reinigung beenden

**Pause und Fortsetzen gibt es in `Clean` nicht.** Der Roboter bietet dafür
nur den simulierten Tastendruck.

### SetButton

```
SetButton <soft|start|spot|back|up|down|IRstart|IRspot|IRfront|IRback|IRleft|IRright|IRhome|IReco>
```

Damit sind die drei zuvor offenen Aktionen belegt:

| set-Kommando | Konsolenkommando | Anmerkung |
|---|---|---|
| `pause` | `SetButton start` | Start während der Reinigung pausiert |
| `resume` | `SetButton start` | derselbe Tastendruck setzt fort – ein Umschalter, kein Zustand |
| `sendToBase` | `SetButton IRhome` | Home-Taste der IR-Fernbedienung; die einzige Entsprechung, die die Firmware anbietet. Falls dein Gerät nicht reagiert: `attr <dev> cmdSendToBase SetButton back` probieren |

### PlaySound

`PlaySound SoundID <n>`, u. a.: 0 Waking Up, 1 Starting Cleaning,
2 Cleaning Completed, 3 Attention Needed, 11 Returning Home, **20 Find me**,
21 Easy Connect Success. `PlaySound Stop` bricht ab.

### Weitere nützliche Kommandos

* `SetNavigationMode Normal|Gentle|Deep|Quick` – Reinigungsmodus. **Nicht
  auslesbar**: ein `GetNavigationMode` gibt es nicht, und der Roboter behält den
  Modus nicht über Läufe hinweg. Er muss deshalb vor jeder Hausreinigung erneut
  gesendet werden. Das Reading `navigationMode` spiegelt daher den zuletzt von
  FHEM gesetzten Wert, nicht den Zustand des Geräts.
* `SetTime Day <0-6> Hour <0-23> Min <0-59> [Sec <0-59>]` – Zeitgeber stellen.
  Ohne Cloud bleibt die Uhr des Roboters sonst stehen; `set <dev> syncTime`
  überträgt die FHEM-Zeit.
* `SetUserSettings Schedule Day <n> Hour <h> Min <m> House|None` – Zeitplan
* `GetSensor Wall|US|Drop|Flight`, `GetLDSScan` (Lidar-Rohdaten),
  `GetDigitalSensors`, `GetButtons`, `GetAccel`, `GetCalInfo`, `GetWarranty`

## Undokumentierte Kommandos

`Help` listet sie **nicht** – sie stecken aber in der Firmware der D-Serie und
sind der Schlüssel zu allem, was über Start und Stop hinausgeht. Gefunden und
entschlüsselt hat sie das Projekt
[OpenNeato](https://github.com/renjfk/OpenNeato) (MIT, © 2026 Soner Köksal);
dieses Modul setzt sie eigenständig in Perl um, gegen deren C++-Original auf
bekannten Werten geprüft.

### SetEvent – die Schnittstelle, über die früher die Cloud sprach

```
SetEvent event <EVENT> SKey <schlüssel>
```

| Event | Wirkung |
|---|---|
| `UIMGR_EVENT_SMARTAPP_START_HOUSE_CLEANING` | Hausreinigung |
| `UIMGR_EVENT_SMARTAPP_START_SPOT_CLEANING` | Spot-Reinigung |
| `UIMGR_EVENT_SMARTAPP_PAUSE_CLEANING` | pausieren |
| `UIMGR_EVENT_SMARTAPP_RESUME_CLEANING` | fortsetzen |
| `UIMGR_EVENT_SMARTAPP_STOP_CLEANING` | beenden |
| `UIMGR_EVENT_SMARTAPP_SEND_TO_BASE` | **zurück zur Basis** |

Das ist der einzige Weg zur Basis. Weder `SetButton IRhome` noch
`SetButton back` tun auf einem D6 irgendetwas. Zudem fährt `SetEvent` die
Zustandsmaschine des Roboters korrekt und erhält Karte und Selbstlokalisierung
über eine Pause hinweg – anders als der simulierte Tastendruck.

### Der Schlüssel

Der `SKey` wird aus der MAC-Adresse berechnet, die `GetVersion` in der Zeile
`Serial Number` als **zweite** Wertespalte mitliefert:

```
Serial Number,GPC33719,40bd32d1097a,P
                       ^^^^^^^^^^^^
```

RC4 mit festem Seed
`68 36 43 58 09 09 3A 3C 2A 7B 59`, 12 Byte Schlüsselstrom, XOR über die
Zeichen der MAC, hex-kodiert – plus ein 25. Zeichen, das das siebte wiederholt.
Implementierung: `NeatoLocal_ComputeSKey` in `FHEM/74_NeatoLocal.pm`, Testvektoren
in `tools/check_module.pl`.

### GetState – der Zustand, den der Roboter selbst kennt

```
Current UI State is: UIMGR_STATE_STANDBY
Current Robot State is: ST_C_Standby
```

Damit entfällt das Raten über `Vacuum_RPM`. Ab Firmware 4.5.3 ist
`robotState` maßgeblich: `uiState` kann auf `UIMGR_STATE_STARTHOUSECLEANING`
hängenbleiben, während der Roboter längst wieder in `ST_C_Standby` steht.
Als Leerlauf gelten `ST_C_Standby`, `ST_C_Idle` und `ST_M2_Charging_StdBy`.
Im `uiState` heißt `CLEANINGPAUSED` pausiert, `DOCKING` auf dem Heimweg und
`CLEANINGSUSPENDED` vom Roboter selbst unterbrochen – letzteres zusammen mit
`ST_M1_Charging_Cleaning`, wenn er wegen leerem Akku laden und danach
weitermachen will.

Vorsicht bei der Auswertung: alle diese Namen enthalten `CLEAN`. Wer darauf
prüft, hält einen unterbrochenen oder abgeschlossenen Lauf für eine laufende
Reinigung.

### Lebensdauerzähler

`GetWarranty` liefert drei Felder fester Breite, alle hexadezimal – erkennbar
am `ValidationCode` daneben und an `05c2`:

```
CumulativeCleaningTimeInSecs,00192364   → 1 647 460 s = 457,6 h
CumulativeBatteryCycles,05c2            → 1474 Ladezyklen
ValidationCode,c2cc3e78
```

`GetUsage` taugt **nicht** zur Gegenprobe: auf einem D6 mit Jahren Laufzeit
meldet es `Total cleaned area: 0`, seine Zähler werden also offenbar nicht
gepflegt. Die Werte aus `GetWarranty` sind die verlässlicheren.

### Weitere

* `GetCharger info` – statische Daten der Smart Battery: Hersteller,
  `Design Capacity mA`, `Design Voltage`.
* `GetCharger data` – die Messwerte des Akkus selbst: `Full Charge Capacity mA`,
  `Remaining Capacity mA`, `Cycle Count`, Spannung, Strom, Temperatur.
  **`Full Charge Capacity` geteilt durch `Design Capacity` ist der Verschleiß**
  und damit die einzige belastbare Aussage über den Akku.
  Die Temperatur steht trotz der Beschriftung `deciC` in Milligrad – dieselbe
  Einheit, die `GetAnalogSensors` mit `mC` korrekt benennt.
  Der `Cycle Count` des Akkus bestätigt nebenbei die hexadezimale Lesart von
  `GetWarranty`: 1484 gegenüber 0x05c2 = 1474, gemessen mit zehn Ladungen
  Abstand.
* `GetRobotPos Raw` / `GetRobotPos Smooth` – Position des Roboters
* `SetUIError clearall` – alle Meldungen quittieren

## No-Go-Linien: was bekannt ist und was nicht

Der D6 konnte No-Go-Linien in der Neato-App. Die Firmware kann es also – die
Frage ist nur, über welche Leitung sie hereinkamen. Dieser Abschnitt hält den
Stand der Recherche fest, damit ihn niemand ein zweites Mal zusammensucht.

**Über die Konsole kamen sie nicht.** Der vollständige `Help`-Satz sind 44
Kommandos – Motoren, Sensoren, WLAN, Töne, Tasten, Testmodi. Kein einziges
erwähnt eine Karte, eine Zone oder eine Grenze; das Wort „map" kommt im ganzen
Dump nicht vor. Von den 16 `Set`-Kommandos setzt keines einen Sensorwert oder
eine Geometrie.

**Das beweist aber nichts**, und das ist der wichtigste Satz hier: `SetEvent`
steht selbst nicht in der `Help`-Liste. Das Kommando, auf dem die halbe
Anbindung dieses Moduls beruht und das den Roboter als einziges zur Basis
schickt, ist in der Selbstauskunft unsichtbar. „Nicht dokumentiert" heißt bei
dieser Firmware nicht „nicht vorhanden".

**Wohin sie stattdessen gingen,** sagt der Roboter selbst. `GetVersion` nennt
seine beiden Gegenstellen im Klartext:

```
Beehive URL, beehive.neatocloud.com
Nucleo URL,  nucleo.neatocloud.com
```

Dorthin schickte er die Karte, von dort kamen die Zonen. Beide Hosts sind seit
der Abschaltung tot. Ob der Roboter sie überhaupt noch auflöst, ist die
billigste offene Frage dieses Themas – ein Blick ins DNS-Log des Routers. Wenn
ja, wäre ein lokaler Stellvertreter der einzige bekannte Weg, auf dem die
**Firmware selbst** die Linien einhält, mit ihrer eigenen Navigation und ihrer
eigenen Sicherheit. Was dahinter liegt – Protokoll, TLS, ob er ohne gültigen
Link etwas annimmt –, ist unbekannt.

**Unabhängige Bestätigung:** [OpenNeato](https://github.com/renjfk/OpenNeato)
benutzt 22 Konsolenkommandos, und keines davon berührt Karten oder Zonen. Das
ist die gründlichste Reverse-Engineering-Arbeit an diesem Roboter. Dort wird
die Funktion gerade als *Guided Clean* gebaut, und zwar durch **Selbstfahren**
entlang eines aufgezeichneten Pfades – nicht dadurch, dass der Firmware Zonen
übergeben werden.

### Warum Selbstfahren teuer ist

`SetMotor` ist der einzige Weg, die Räder zu stellen, und bringt drei Haken mit:

```
SetMotor - ... (TestMode Only)
  Brush - Brush motor forward (Mutually exclusive with wheels and vacuum.)
  WDTOn - Enable Motor Power Watchdog Toggle. It must be enable for motor power on.
```

* **TestMode.** Dort reinigt der Roboter nicht von selbst und gehorcht seinen
  Tasten nicht. Wer fährt, übernimmt auch die Absturzsicherung.
* **Fahren und Bürste/Saugen schließen sich in einem Kommando aus.** Ob sie
  sich nacheinander kombinieren lassen, steht nirgends und ist ungeprüft.
* **Ein Motor-Watchdog** muss laufend getoggelt werden. Über die Kette
  FHEM → Brücke → Konsole ist das eine andere Klasse von Echtzeitanforderung
  als alles, was dieses Modul sonst tut.

### Die Magnetsensoren

Vor der Cloud löste Neato das Problem mit magnetischen Begrenzungsstreifen, und
die Hardware dafür ist noch da:

```
MagSensorType,1,MAG_SENSOR_ORIG
MagSensorLeft,VAL,0
MagSensorRight,VAL,0        (aus GetAnalogSensors)
```

Echtes Magnetband funktioniert damit heute, ohne jede Änderung am Modul. Der
Gedanke, das Signal **vorzutäuschen** – eine Spule an den Sensoren, von der
Brücke geschaltet, sobald die Position in eine verbotene Zone läuft – ist
reizvoll, weil der Roboter dann mit seiner eigenen Navigation ausweicht. Er ist
hier nicht umgesetzt: es gibt keinen Softwareweg dorthin, es wäre ein Eingriff
in die Hardware jedes einzelnen Geräts, und offen bliebe, ob der Sensor auf ein
statisches Feld überhaupt anspricht und was der Roboter tut, wenn das „Band"
nicht aufhört. Messen ließe sich das: die Sensorwerte sind über
`get <dev> sensors` lesbar.

### Kurzfassung

| Weg | Stand |
|---|---|
| Konsolenkommando für Zonen | keines bekannt, aber `Help` ist nachweislich unvollständig |
| `SetEvent` | trägt nur Ereignisname und Schlüssel, kein Nutzlastfeld |
| Lokaler Cloud-Stellvertreter | unbekannt, und die einzige Variante, bei der die Firmware selbst ausweicht |
| Selbstfahren (*Guided Clean*) | machbar, aber TestMode, Watchdog und Sicherheit gehen an uns über |
| Magnetband | funktioniert heute, ohne Software |
| Magnetsignal vortäuschen | kein Softwareweg, Hardwareeingriff, ungeprüft |

## Finger weg

`Upload` (Firmware), `ClearFiles All` (Logs), `SetUserSettings Reset`
(Werkseinstellungen), `SetSystemMode Shutdown|PowerCycle`, `SetMotor`,
`DiagTest`, `SetFuelGauge`. Das Modul sendet nichts davon; über `set raw`
sind sie erreichbar, aber dann auf eigene Verantwortung.

## Bekannte Stolperfallen

* **Fehler 220 über USB.** Ältere Firmware verweigert die Reinigung, solange
  ein USB-Host angesteckt ist. Betrifft nur den USB-Transport, nicht den
  internen Debug-Port.
* **Schlafender Roboter.** Nach längerer Ruhe verwirft die Konsole das erste
  Kommando, und der USB-Port ist unter Umständen gar nicht da. Erst wecken.
* **Zustandserkennung.** Der Roboter meldet keinen expliziten „ich reinige
  gerade“-Status. Das Modul leitet ihn aus `Vacuum_RPM` (`GetMotors`) ab und
  nimmt zwischen Startbefehl und nächster Abfrage optimistisch `cleaning` an.
* **Code 200 ist kein Fehler.** Ein gesunder Roboter füllt beide Fächer mit
  `200 -  (UI_ALERT_INVALID)`. Das heißt „hier steht nichts", nicht „Störung".
  Ein leeres Fach ist also keine fehlende Zeile, sondern eine Zeile mit
  diesem Code. Echte Fehler der D-Serie liegen im Bereich 24x, etwa
  249 `UI_ERROR_DUST_BIN_MISSING`.
* **Alarm ist kein Fehler.** `GetErr` liefert `Error` und `Alert` getrennt.
  Ein voller Staubbehälter (Alert 248) darf den Roboter nicht in den
  Fehlerzustand versetzen – das Modul trennt beides.
