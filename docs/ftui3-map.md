# Briefing: eine FTUI3-Komponente für die Karte

Dieses Dokument richtet sich an jemanden, der eine Anzeige für die vom Modul
`74_NeatoLocal` aufgezeichneten Reinigungsläufe baut. Es beschreibt das
Datenformat, die Rechenschritte und die Stellen, an denen schon einmal etwas
schiefgegangen ist.

**Was hier nicht drinsteht:** wie FTUI3-Komponenten aufgebaut sind. Das weiß
dieses Dokument nicht und rät auch nicht – das gehört nachgeschlagen.

## Woher die Daten kommen

Das Modul zeichnet während einer Reinigung auf und schreibt eine Datei je Lauf.
Es zeichnet **nichts** – es schreibt Daten, die Darstellung ist Sache der
Anzeige.

* Verzeichnis: Attribut `trackDir`, Standard `./www/neato`, also in der Regel
  `/opt/fhem/www/neato/`
* Dateiname: `<Gerät>-<JJJJ-MM-TT_HH-MM-SS>.jsonl`
* Aufzeichnung ist **standardmäßig aus**: `attr <dev> trackRuns 1`
* Scans nur mit `attr <dev> mapInterval <Sekunden>` (0 = nur die Spur)
* Alte Sitzungen verschwinden nach `trackKeepDays` Tagen, Standard 14

Readings, die die Anzeige ohne Dateizugriff nutzen kann:

| Reading | Inhalt |
|---|---|
| `trackFile` | Pfad der aktuellen bzw. letzten Sitzung |
| `trackPoints` | Positionsproben des letzten Laufs |
| `trackScans` | Lidar-Scans des letzten Laufs |
| `trackDistance` | gefahrene Strecke in Metern |
| `trackDuration` | Dauer in Sekunden |
| `state` | u. a. `cleaning`, `docked`, `robotSilent` |

`trackFile` wird beim **Start** eines Laufs gesetzt, die übrigen beim Ende.
Für eine Live-Ansicht also `trackFile` beobachten und die Datei nachladen,
solange `state` auf `cleaning` steht.

## Das Dateiformat

JSON Lines, eine Zeile je Datensatz, vier Sorten. Zeilen mit `#` am Anfang sind
Kommentare (nur in den Fixtures im Repo, nicht in echten Aufzeichnungen).

```json
{"device":"Staubsauger","started":"2026-09-20_11-59-11","module":"0.19.0","unit":"m"}
{"t":64766.91,"x":0.000,"y":0.000,"th":0.0}
{"scan":{"x":1.204,"y":0.418,"th":92.0,"speed":5.02,"pose":"Smooth","tilt":[-2.33,-1.20,0.951],"pts":[[0,1284],[1,1266]]}}
{"summary":{"points":549,"scans":50,"distance":137.8,"rotation":20500,"seconds":1500}}
```

* **Kopf** – einmal am Anfang. `unit` ist die Einheit der Koordinaten (`m`).
* **Pose** – eine je Abtastung, Standard alle 3 s (`trackInterval`).
  `t` ist die Uhr des Roboters in Sekunden, `x`/`y` in Metern, `th` in Grad.
* **Scan** – eine je Lidar-Umdrehung. `pts` sind `[Winkel in Grad, Entfernung
  in mm]`, gemessen von der Pose **in derselben Zeile**. `speed` ist die
  Drehzahl des Lidar in Hz, `pose` die verwendete Positionsquelle.
  `tilt` ist optional (ab Modul 0.22.0) und trägt `[Pitch, Roll, |a|]` in Grad
  bzw. g – siehe unten. Ältere Aufzeichnungen haben es nicht.
* **Zusammenfassung** – einmal am Ende. Fehlt, solange der Lauf noch läuft;
  ihr Vorhandensein ist das Kennzeichen einer abgeschlossenen Sitzung.

Die Reihenfolge ist chronologisch. Jedem Scan geht die Pose voraus, aus der er
gemessen wurde, und es folgt eine zweite unmittelbar danach – daran lässt sich
ablesen, wie weit sich der Roboter während des Scans bewegt hat.

Die Punkte sind beim Schreiben bereits gefiltert: keine Nullwerte, nichts
jenseits von `mapMaxRange` (Standard 6000 mm), keine Zeilen mit Fehlercode.

## Punkte an ihren Platz rechnen

```
x = pose.x + entfernung_mm / 1000 * cos(pose.th + winkel)
y = pose.y + entfernung_mm / 1000 * sin(pose.th + winkel)
```

Beides in **Grad**, gegen den Uhrzeigersinn, der Nullpunkt des Lidar zeigt nach
vorn. Diese Formel ist **gemessen**, nicht hergeleitet: von 96 geprüften
Varianten ist sie die schärfste, mit 18 % Abstand zur zweitbesten.

**Falle:** die zweitbeste ist die Spiegelung (`θ→−θ`, `a→−a`, `+180°`). In einer
halbwegs symmetrischen Wohnung sieht sie fast genauso ordentlich aus. Wer die
Formel „aufräumt" und dabei ein Vorzeichen dreht, merkt es am Ergebnis nicht.

**Falle:** in SVG und Canvas wächst `y` nach **unten**, in den Daten nach oben.
Ohne Spiegelung beim Zeichnen steht die Wohnung auf dem Kopf.

## Aus Punkten eine Karte machen

Die Endpunkte allein zu zeichnen ergibt eine Punktwolke, die aussieht wie eine
Strichzeichnung. Der Grund: ein Strahl, der bei 3 m endet, hat auch gemessen,
dass der **ganze Weg dorthin frei** war – und genau das wird sonst weggeworfen.

Verfahren:

1. Raster über die Fläche legen, Zellgröße 5 cm hat sich bewährt.
2. Für jeden Punkt eines Scans die Zellen zwischen Sensorposition und Endpunkt
   bestimmen (Bresenham) und je als **frei** zählen.
3. Die Zelle des Endpunkts als **Wand** zählen.
4. Am Ende entscheidet das Verhältnis: `treffer / (treffer + durchgänge)`. Ab
   0,25 gilt die Zelle als Wand, darunter als frei. Zellen mit weniger als zwei
   Beobachtungen bleiben unbekannt.

Hinter dem Endpunkt wird **nichts** behauptet – dort war der Strahl nie.

Das Raster wächst nicht mit der Datenmenge: 13 × 10 m sind bei 5 cm rund 52 000
Zellen, ob 14 000 oder 400 000 Punkte hineinfallen. Mehr Messungen machen es
nur sicherer. Für die Darstellung lohnt es daher, waagerecht benachbarte Zellen
zu einem Rechteck zusammenzufassen; einzelne Quadrate ergeben ein zähes
Dokument ohne sichtbaren Gewinn.

## Größenordnungen

Gemessen an einem 25-Minuten-Lauf mit `mapInterval 30`:

| | |
|---|---|
| Posen | 549 (alle 3 s) |
| Scans | 50, je ~276 gültige Punkte |
| Punkte gesamt | 13 788 |
| Datei | 165 kB |
| Fläche | 12,6 × 9,5 m |

Mit `mapInterval 5` werden es rund 300 Scans, 83 000 Punkte, 0,9 MB. Das Gitter
bleibt gleich groß. Die Berechnung dauert in Python 0,1 s; in JavaScript ist sie
unkritisch, bei den größeren Mengen aber ein Kandidat für einen Worker.

## Referenzumsetzung im Repo

* `tools/track_map.py` – Datei lesen, Punkte umrechnen, Belegungsgitter
* `tools/render_track.py` – zeichnet eine Sitzung als SVG (`--points` für die
  rohen Endpunkte, `--cell` für die Zellgröße)
* `tools/check_track.py` – prüft Format, Konvention und Strahlengang
* `docs/reference-track-botvac-d6.jsonl` – echte, ausgedünnte Aufzeichnung.
  **Damit lässt sich ohne Roboter und ohne FHEM entwickeln.**

## Schräglage: warum `tilt` mitgeschrieben wird

Arbeitet sich der Roboter an einer Engstelle hoch, steht er schräg, und dann
kippt die Scanebene mit. Das erzeugt **keine** Streuung, sondern eine erfundene
Wand: zwei Ebenen schneiden sich in einer Geraden, die Scanebene schneidet den
Boden, und in Polarkoordinaten ist eine Gerade `d/cos(a)` – dieselbe Form wie
eine echte Wand. Nachgerechnet bei 4° Neigung und 80 mm Lidar-Höhe stimmt das
auf zwei Millimeter.

Und sie liegt dort, wo echte Wände liegen, nämlich bei `h / sin(Neigung)`:

| Neigung | Boden erscheint bei |
|---|---|
| 1° | 4,6 m |
| 2° | 2,3 m |
| 3° | 1,5 m |
| 5° | 0,9 m |

Bei realistischen 2–5° also 0,9 bis 2,3 m. **Innerhalb einer Umdrehung ist das
von einer Wand nicht zu unterscheiden** – weder über die Form noch über die
Entfernung. Deshalb wird der Winkel gemessen und mitgeschrieben, statt ihn
später aus den Punkten zu rekonstruieren.

Zwei Dinge dazu, bevor jemand darauf filtert:

* **Der Sensor ist nicht kalibriert.** Ein D6, der waagerecht auf der Basis
  steht, meldet −2,33° / −1,20° bei 0,951 g. Ein Filter muss also auf die
  Abweichung vom Ruhewert *dieses Laufs* gehen, nicht auf den Absolutwert.
* **Das dritte Feld ist der Betrag** der gemessenen Beschleunigung. Ein
  Beschleunigungssensor misst alles, nicht nur die Schwerkraft – beim Anfahren
  und Bremsen kippt der scheinbare Winkel, ohne dass der Roboter kippt. Eine
  Probe, deren Betrag vom Ruhewert abweicht, wurde beim Beschleunigen genommen
  und ist weniger wert.

Eine Schwelle gibt es bewusst **noch nicht**. Sie gehört aus Daten abgelesen,
nicht geraten.

## Mehrere Läufe: der gemeinsame Grundriss

Das oben Beschriebene ist ein einzelner Lauf. Mehrere zusammengelegt ergeben
einen Grundriss, und den rechnet **das Modul**, nicht die Anzeige:

* Datei: `plan-<Gerät>.json` in `trackDir`, also neben den Aufzeichnungen
* Reading: **`planFile`** nennt den Pfad, genau wie `trackFile` den der
  laufenden Sitzung – die Komponente kann ihn binden, statt ihn als Attribut
  eingetragen zu bekommen
* dazu `planCells` (wie viele Zellen), `planRuns` (wie viele Aufzeichnungen
  eingegangen sind) und `planState` (`ok`, `ok, 1 did not fit (0.33)`,
  `failed: …`) – die Zahl in Klammern ist die Güte, mit der der ausgelassene
  Lauf eingepasst worden wäre
* die Güte **aller** Läufe steht im Feld `scores` der Plandatei; die Anzeige
  braucht es nicht, es ist Beweissicherung für die Frage, ob die Schwelle von
  0,45 an der richtigen Stelle liegt
* gerechnet wird auf `set <Gerät> buildPlan` oder, mit `attr <Gerät> planAuto 1`,
  nach jeder Reinigung

Dateiformat und Verfahren stehen in `docs/plan-format.md` des Repos
`chrisse1/fhem-ftui-components-neatomaps`; die Referenzfassung dieser Seite
liegt hier in `FHEM/lib/NeatoLocalPlan.pm` und wird von `tools/check_plan.pl`
gegen die JavaScript-Fassung gehalten.

## Was die Karte nicht ist

* **Kein Grundriss der Wohnung, sondern des Laufs.** Fehlt ein Raum, war der
  Roboter nicht drin – in einem beobachteten Lauf fehlten Ess- und Wohnzimmer,
  weil er dort nie hingefahren ist. Einzelne Punkte in einem sonst leeren
  Bereich sind Wände, die der Lidar durch eine Türöffnung gesehen hat.
* **Nicht über Läufe hinweg gültig.** Jede Sitzung hat ihren eigenen Nullpunkt;
  zwei Läufe lassen sich nicht ohne Weiteres übereinanderlegen.
* **Nicht so genau wie die App von Neato.** Der Roboter wertet intern rund 7500
  Umdrehungen je Lauf aus und rechnet Scan-Matching und Schleifenschluss; wir
  sehen davon nur das Ergebnis in Form der Position und nehmen 50 bis 300
  Stichproben.
