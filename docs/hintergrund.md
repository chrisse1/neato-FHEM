# Hintergrund

Warum das Modul und die Brücke an einigen Stellen so gebaut sind, wie sie
gebaut sind.

Dieses Dokument richtet sich an den, der am Modul weiterbaut oder einen
Fehler sucht. Zum Benutzen braucht man es nicht – dafür ist die
[README](../README.md) da.

Weitere Hintergründe stehen in eigenen Dokumenten:

| Thema | Dokument |
|---|---|
| Kommandos der Konsole, `SetEvent`, No-Go-Linien | [serial-commands.md](serial-commands.md) |
| Karte, Koordinaten, Belegungsgitter, Schräglage | [ftui3-map.md](ftui3-map.md) |
| Verdrahtung und Stromversorgung der Brücke | [hardware.md](hardware.md) |
| Brücke von Hand flashen | [flashing-esp32c3.md](flashing-esp32c3.md) |

---

## Brücke flashen

### Das Image wird geprüft, bevor das Board es sieht

Bevor das Board angefasst wird, prüft das Modul, ob es überhaupt eine Firmware
vor sich hat – Größe und das Magic-Byte `0xE9`. Eine abgebrochene Übertragung
oder eine HTML-Fehlerseite statt des Images führt so zu einer Meldung statt zu
einem halb beschriebenen Flash.

### Wo die Zugangsdaten hingeschrieben werden

`flashESP` holt das Image, das die CI dieses Projekts baut, schreibt es mit
`esptool` an Offset 0 und legt die Zugangsdaten in einem zweiten Schreibvorgang
als kleinen Block in die Storage-Partition. Beim ersten Start übernimmt die
Firmware sie ins NVS und löscht den Block wieder.

Sie können **nicht** ins Anwendungsimage geschrieben werden: das trägt eine
SHA-256, die der Bootloader prüft, und ein hineingepatchtes Byte hindert das
Board am Starten. Den Offset der Partition nimmt das Modul aus der Textdatei
neben dem Image, die die CI aus der Partitionstabelle *dieses* Images erzeugt –
eine hier eingetragene Zahl wäre nur so lange richtig, bis jemand das
Partitionsschema ändert.

Fehlt bei einem eigenen Image die Textdatei daneben, werden keine Zugangsdaten
geschrieben, und das Modul sagt das, statt ein halb eingerichtetes Board zu
hinterlassen.

### Warum `update` das Image nicht holt

`update` bringt ausschließlich die Perl-Dateien – die Indexdatei führt nichts
anderes auf. Das ist Absicht: das Image ist gut ein Megabyte groß und wird pro
Brücke genau einmal gebraucht, es hat auf jedem FHEM-Server nichts verloren.
`flashESP` lädt es bei Bedarf selbst.

### Update über Funk

Das ArduinoOTA-Protokoll ist in reinem Perl im Modul umgesetzt, `espota.py`
aus dem Arduino-Core braucht es also nicht. `tools/check_ota.pl` fährt den
Ablauf gegen einen Stellvertreter der Brücke und vergleicht das angekommene
Image Byte für Byte.

---

## WLAN der Brücke

### Neustart mit abgeschaltetem Funkmodul

Vor jedem Software-Neustart wird das Funkmodul abgeschaltet, und scheitert der
erste Verbindungsversuch, wiederholt das Board ihn auf einem wirklich neu
gestarteten Funkmodul. Ein Software-Reset lässt die WLAN-Hardware sonst im
vorherigen Zustand stehen; eine Verbindung, die erst nach dem Ziehen des
Steckers klappt, ist genau dieses Bild – und alles, was danach gemeldet wird
(Trennungsgrund, Scan), beschreibt dann einen Fehler, den es nicht gibt.

Nach `wifi save` **startet das Board neu**, statt im Betrieb umzuschalten. Das
ist der verlässlichere Weg – Webserver, mDNS und OTA werden sauber neu
aufgesetzt – und beweist nebenbei, dass die Zugangsdaten den Neustart
überstanden haben. `wifiESP` wartet den Neustart ab und fragt danach die
Adresse ab; meldet das Board dann den Access Point statt einer Adresse im
Heimnetz, fragt es `wifi status` und `wifi scan` ab und stellt die Ursache in
`lastFlash` fest.

### Trennungsgründe

Maßgeblich ist der Trennungsgrund, den das Board vom Verbindungsversuch selbst
mitbringt: 15 oder 204 heißt Passwort abgelehnt, 201 heißt Netz nicht
gefunden, 202 und 203 heißen vom Router abgewiesen. Grund 2 ist ausdrücklich
mehrdeutig – dieselbe Meldung schickt ein Router auch bei MAC-Filter oder
vollem Client-Limit – und wird deshalb nicht dem Passwort angelastet. Die
Meldung nennt dann die MAC des Boards, also das, wonach in der Geräteliste des
Routers zu suchen ist, und die Zeichenzahl des angekommenen Passworts. Die
Scan-Liste steht nur daneben, mit Pegel und Kanal zu jedem Netz – sie ist ein
Indiz, kein Beweis, denn ein Scan kann unvollständig sein.

### Länderkennung

Die Firmware stellt die Funk-Länderkennung auf `DE` (Kanäle 1–13). Ohne das
bleibt ein Board bei der Werkseinstellung „world safe" stehen und lässt die
Kanäle 12 und 13 aus jedem Scan heraus – ein Router, der dort funkt, existiert
für das Board dann schlicht nicht. Andere Region: `-DWIFI_COUNTRY=\"…\"` beim
Übersetzen.

### Zugangsdaten zurücklesen

`wifi save` liest die Zugangsdaten vor dem Neustart wieder aus dem Flash zurück
und meldet `ERR storage did not keep the credentials`, wenn dort nichts
angekommen ist. Sonst sähe ein leerer Speicher nach dem Neustart genauso aus
wie ein falsches Passwort.

### Kein Stromsparmodus

Die Brücke schaltet den Stromsparmodus des Funkmoduls ab. Er parkt das Funkteil
zwischen den Beacons, was für ein Gerät richtig ist, das nur sendet – die
Brücke muss aber *antworten*, und eingehende Verbindungen kommen dann verspätet
oder gar nicht an.

### Überwachung der Verbindung

Die Station-Verbindung wird überwacht: ist sie 30 Sekunden weg, wird das
Funkmodul neu gestartet und neu verbunden, nach vier erfolglosen Versuchen
öffnet das Board den Setup-Access-Point. `info` zählt mit, wie oft die
Verbindung abgerissen ist (`link drops`) – ein Board, das sich verbindet und
dann verschwindet, ist ein anderer Fehler als eines, das nie hochkommt.

Scheitert das Verbinden im laufenden Betrieb, öffnet das Board den Access Point
**zusätzlich** zur Station-Seite und versucht weiter, das konfigurierte Netz zu
erreichen. Ein Router, der kurz weg ist, strandet es also nicht bis zum nächsten
Stromausfall.
