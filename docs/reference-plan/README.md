# Der Referenzfall für den Grundriss

Drei Aufzeichnungen derselben erfundenen Wohnung, jede in ihrem eigenen
Bezugsrahmen, und das Ergebnis, das die JavaScript-Referenz daraus macht.
Daran wird `FHEM/lib/NeatoLocalPlan.pm` gemessen – `tools/check_plan.pl` tut
genau das, und die CI führt es bei jedem Push aus.

| Datei | |
|---|---|
| `room-a.jsonl` | die Wohnung, ungedreht |
| `room-b.jsonl` | um 90° gedreht, um (3,5 / −2) verschoben |
| `room-c.jsonl` | um 200° gedreht, um (−1,5 / 4,25) verschoben, nur halb abgefahren |
| `moves.json` | die Wandsegmente und die angewandten Drehungen, auf den Zentimeter |
| `plan.json` | was die JavaScript-Referenz daraus macht: 726 Zellen aus 3 Läufen |

Die Wohnung ist ein **L**, kein Rechteck mit Mittelwand: letzteres sieht auf
dem Kopf genauso aus, dann gäbe es keine richtige Antwort zu finden, und ein
Test, der aus gutem Grund manchmal fehlschlägt, ist schlechter als keiner.

Aus `moves.json` lässt sich die Lösung von Hand nachrechnen. Wird Rahmen *F*
gewählt, gehört Lauf *X* dorthin gedreht um `θ_F − θ_X` und verschoben um
`t_F − R(θ_F − θ_X)·t_X`. Mit `room-b` als Rahmen landet `room-c` bei 250° und
(−1,01 / −1,96).

## Herkunft

Übernommen aus `test/fixtures/plan/` des Repos
`chrisse1/fhem-ftui-components-neatomaps` (MIT), erzeugt dort von
`tools/make-plan-fixture.mjs`. Sie liegen hier, damit unsere CI die Naht
zwischen beiden Implementierungen ohne node prüfen kann. Ändert sich der
Referenzfall drüben, gehört er hier nachgezogen.
