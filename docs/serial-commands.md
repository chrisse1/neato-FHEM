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

Diese sind durch bestehende Open-Source-Implementierungen bzw. das Neato
Programmer's Manual gedeckt und werden vom Modul verwendet:

| Kommando | Zweck | Ausgewertete Felder |
|---|---|---|
| `GetCharger` | Akku- und Ladestatus | `FuelPercent`, `ChargingActive`, `ExtPwrPresent`, `BatteryOverTemp`, `VBattV` |
| `GetErr` | aktueller Fehler | Zeile im Format `<code> - <text>`, z. B. `220 - Please put my Dirt Bin back in.` |
| `GetMotors` | Motorzustand | `Vacuum_RPM` > 0 ⇒ der Roboter saugt |
| `GetVersion` | Gerätedaten | `ModelID`, `Serial Number`, `MainBoard Software` |
| `GetAnalogSensors` | Analogsensorik | roh (`get sensors`) |
| `Help [cmd]` | Kommandoliste des Roboters | roh |
| `TestMode On/Off` | Diagnosemodus | – |
| `Clean House` | Hausreinigung starten | – |
| `Clean Spot` | Spot-Reinigung starten | – |
| `Clean Stop` | Reinigung beenden | – |
| `PlaySound <id>` | Ton abspielen | – |

Weitere dokumentierte Kommandos, die sich über `set raw` / `get raw` nutzen
lassen: `GetAccel`, `GetButtons`, `GetCalInfo`, `GetDigitalSensors`,
`GetLDSScan` (Lidar-Rohdaten!), `GetLifeStatLog`, `GetSchedule`, `GetTime`,
`GetUserSettings`, `GetWarranty`, `NewBattery`, `SetUserSettings Reset`,
`ClearFiles All`.

## Nicht belegte Kommandos

Für diese Aktionen ist die Syntax auf der D-Serie **nicht verifiziert**. Das
Modul rät nicht, sondern liefert eine Fehlermeldung mit Verweis auf das
zugehörige Attribut:

| set-Kommando | Attribut | Vorgabe |
|---|---|---|
| `pause` | `cmdCleanPause` | leer |
| `resume` | `cmdCleanResume` | leer |
| `sendToBase` | `cmdSendToBase` | leer |

Vorgehen:

```
get Staubsauger help Clean
attr Staubsauger cmdSendToBase <gefundenes Kommando>
```

Wenn du die Syntax auf deinem Gerät ermittelt hast: bitte als Issue melden,
dann wandert sie als Vorgabe ins Modul.

## Bekannte Stolperfallen

* **Fehler 220 über USB.** Solange ein USB-Host angesteckt ist, startet der
  Roboter keine Reinigung. Betrifft nur den USB-Transport, nicht den internen
  Debug-Port.
* **Schlafender Roboter.** Nach längerer Ruhe verwirft die Konsole das erste
  Kommando. `neato-serial` sendet deshalb erst ein Dummy-Wort („wake-up“).
  Bei fester Verkabelung über den Debug-Port ist das in der Praxis kein Thema;
  falls doch, hilft ein `set <device> raw wake-up` vor dem eigentlichen Befehl.
* **Zustandserkennung.** Der Roboter meldet keinen expliziten „ich reinige
  gerade“-Status. Das Modul leitet ihn aus `Vacuum_RPM` (`GetMotors`) ab und
  nimmt zwischen Startbefehl und nächster Abfrage optimistisch `cleaning` an.
