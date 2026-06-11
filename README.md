# NTPServer

Native macOS-Menüleisten-App, die einen einfachen NTP-Server betreibt.
Swift/AppKit, **kein Homebrew**, keine Runtime-Abhängigkeiten – das fertige
`.app` ist eigenständig.

**Modell:** Es gibt genau **einen** Server – einen root-LaunchDaemon, der
boot-fest auf dem konfigurierten UDP-Port läuft. Die Menüleisten-App ist die
**Steuerung**: Server aktivieren/deaktivieren, Port konfigurieren, Status und
Log anzeigen, „Beim Anmelden öffnen". (Port 123, den echte NTP-Clients erwarten,
darf nur root binden – deshalb der Daemon statt eines App-internen Servers.)

## Voraussetzung
Apple Command Line Tools (enthalten die Swift-Toolchain):
```bash
xcode-select --install
```
Kein volles Xcode-GUI nötig.

## Bauen
```bash
./build_app.sh
open ./dist/NTPServer.app
```
Erststart ggf. per Rechtsklick → „Öffnen" (Gatekeeper, da ad-hoc signiert).
In der Menüleiste erscheint ein 🕐-Symbol mit allen Funktionen.

## Bedienung
Alles läuft über das Menü:

1. **Port ändern…** – frei wählbarer UDP-Port (1–65535), Default **123**. Wird
   gemerkt und automatisch für den Server (Daemon) verwendet.
2. **Server aktivieren** – installiert und startet den root-Daemon auf dem
   konfigurierten Port. Es erscheint **einmal** ein Admin-Passwort-Dialog; danach
   läuft der Server boot-fest. **Server deaktivieren** entfernt ihn wieder.
3. Änderst du den Port bei aktivem Server, wird der Daemon automatisch mit dem
   neuen Port neu installiert (ein weiterer Admin-Dialog).
4. **Status** und **Log anzeigen…** zeigen Zustand bzw. das Daemon-Log.
5. **Beim Anmelden öffnen** lässt die Steuer-App beim Login erscheinen (der
   Server selbst läuft ohnehin boot-fest, unabhängig von der App).

Hintergrund: Port < 1024 (z. B. 123) darf nur **root** binden. Der Daemon läuft
als root und kann das; eine normale App nicht. Daher gibt es genau einen Server
(den Daemon), nicht zusätzlich einen App-internen.

Installierte Artefakte (von der App verwaltet):
- Binary: `/usr/local/libexec/ntpserver`
- Plist:  `/Library/LaunchDaemons/app.ntpserver.daemon.plist`
- Log:    `/var/log/ntpserver.log` (im Logviewer der App sichtbar)

## Testen (Entwicklung)
Das Server-Binary lässt sich headless auf einem Test-Port starten und abfragen –
ohne Daemon-Installation und ohne root:
```bash
# Server auf Test-Port starten:
NTP_HEADLESS=1 NTP_PORT=12300 ./.build/release/NTPServer &

# Hinweis: macOS-`sntp` interpretiert "host:port" als Hostnamen
# ("DNS lookup failure") – die host:port-Syntax funktioniert hier NICHT.
# Stattdessen mit einem eigenen UDP-Client prüfen, z. B. Python:
python3 - <<'PY'
import socket, struct, time
NTP_DELTA = 2208988800
pkt = bytearray(48); pkt[0] = (4 << 3) | 3            # VN=4, Mode=3 (client)
struct.pack_into("!II", pkt, 40, int(time.time())+NTP_DELTA, 0)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(bytes(pkt), ("127.0.0.1", 12300))
d, _ = s.recvfrom(512)
sec, _ = struct.unpack("!II", d[40:48])              # Transmit-Timestamp
print("mode=%d stratum=%d refid=%r serverzeit=%s"
      % (d[0] & 7, d[1], d[12:16], time.ctime(sec - NTP_DELTA)))
PY
```
Erwartet bei synchroner OS-Uhr: `mode=4 stratum=2 refid=b'LOCL'` und eine
plausible Serverzeit.

## Hinweise
- Stratum/LI werden aus dem Kernel-Sync-Status der macOS-Uhr abgeleitet:
  synchron → Stratum 2, refid „LOCL"; nicht synchron → LI=Alarm, Stratum 16,
  damit brave Clients die Zeit verwerfen statt eine falsche zu übernehmen.
- Paketbau ist gegen einen echten UDP-Client verifiziert (Originate-Echo,
  Receive-/Transmit-Timestamps korrekt).
- Ein Binary, zwei Modi: `NTP_HEADLESS=1` = reiner Server ohne GUI (so läuft der
  Daemon), `NTP_PORT=<port>` setzt den Port. Ohne `NTP_HEADLESS` startet die
  Steuer-App in der Menüleiste.

## Lizenz
MIT – siehe [LICENSE](LICENSE).
