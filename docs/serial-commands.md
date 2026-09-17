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

* `SetNavigationMode Normal|Gentle|Deep|Quick` – Reinigungsmodus
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
Als Leerlauf gelten `ST_C_Standby`, `ST_C_Idle` und `ST_M2_Charging_StdBy`;
`CLEANINGPAUSED` im `uiState` heißt pausiert, `DOCKING` heißt auf dem Heimweg.

### Weitere

* `GetRobotPos Raw` / `GetRobotPos Smooth` – Position des Roboters
* `SetUIError clearall` – alle Meldungen quittieren

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
