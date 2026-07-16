# CLAUDE.md – Hinweise für Claude Code

## Projekt
Native macOS-App (Swift/AppKit), die einen einfachen NTP-Server betreibt.
**Ein Server** = ein root-LaunchDaemon (boot-fest, konfigurierbarer Port). Die
Menüleisten-App ist reine **Steuerung** (aktivieren/deaktivieren, Port, Status,
Log). **Ohne Homebrew**, keine Runtime-Abhängigkeiten, Build nur über die Apple
Command Line Tools. (Port 123 braucht root → Daemon statt App-internem Server.)

## Architektur
- `Sources/NTPServer/main.swift` – Einstieg. Zwei Modi aus einem Binary:
  Headless-Server (Env `NTP_HEADLESS=1`, so läuft der Daemon) oder
  `.accessory`-Steuer-App (kein Dock-Icon).
- `Sources/NTPServer/Config.swift` – zentrale Namen/Pfade (Bundle-ID
  `app.ntpserver`, Daemon-Label, Logpfad, `defaultPort`) + Plist-Erzeugung zur
  Laufzeit mit konfiguriertem Port.
- `Sources/NTPServer/AppDelegate.swift` – Steuer-Menü (`NSStatusItem`): Server
  aktivieren/deaktivieren (= Daemon install/uninstall), Port ändern (persistiert
  in `UserDefaults`, bei aktivem Daemon Auto-Neuinstallation), „Beim Anmelden
  öffnen", Logviewer, Status.
- `Sources/NTPServer/DaemonControl.swift` – Install/Uninstall des root-Daemons
  via einmaligem Admin-Prompt (`osascript … with administrator privileges`);
  liest installierten Port aus der Plist und prüft Laufzustand (`pgrep`).
- `Sources/NTPServer/LogWindowController.swift` – Log-Fenster (Steuer-Ereignisse
  + Daemon-Logfile, Auto-Refresh).
- `Sources/NTPServer/MailNotifier.swift` – `MailConfig` (Relay-Host/Port,
  Absender/Empfänger; Default-Host `::1`, **nicht** `127.0.0.1`, siehe unten) +
  minimaler Klartext-SMTP-Client auf POSIX-Sockets.
- `Sources/NTPServer/CrashMarker.swift` – Marker für die Absturzerkennung
  (setzen/prüfen/entfernen) + sauberes Beenden per `DispatchSource`-Signalquelle.
- `Sources/NTPServer/NTPServer.swift` – UDP-Listener (Network framework) +
  NTP-Paketbau (RFC 5905, vereinfacht). Leitet Stratum/LI aus dem
  Kernel-Sync-Status ab.
- `Sources/CNTPSync/` – C-Shim, liest `ntp_adjtime` (Sync-Status der OS-Uhr);
  in Swift sind `timex`/`ntp_adjtime` nicht sichtbar, daher eigenes C-Target.
- `build_app.sh` – kompiliert (`swift build -c release`) und bündelt `.app`.

Vom Daemon (zur Laufzeit) verwaltete Artefakte: Binary
`/usr/local/libexec/ntpserver`, Plist
`/Library/LaunchDaemons/app.ntpserver.daemon.plist`, Log `/var/log/ntpserver.log`.

## Build & Test
```bash
xcode-select --install      # nur falls Toolchain fehlt
./build_app.sh
open ./dist/NTPServer.app
# Test gegen den laufenden Server (Test-Port 12300):
# ACHTUNG: macOS-`sntp` versteht "host:port" NICHT (DNS lookup failure).
# Server headless starten und mit eigenem UDP-Client prüfen (siehe README):
NTP_HEADLESS=1 NTP_PORT=12300 ./.build/release/NTPServer &

# Absturz-Mail testen, ohne root und ohne echte Mail: Marker-Pfad umbiegen
# (NTP_STATE_PATH – der Default unter /usr/local braucht root) und gegen einen
# Wegwerf-SMTP-Server statt gegen MailRelay senden. Marker vorlegen = Absturz.
echo "pid=1 port=123" > /tmp/ntp.state
NTP_HEADLESS=1 NTP_PORT=12300 NTP_STATE_PATH=/tmp/ntp.state \
  NTP_MAIL_HOST=::1 NTP_MAIL_PORT=2526 \
  NTP_MAIL_FROM=a@example.invalid NTP_MAIL_TO=b@example.invalid \
  ./.build/release/NTPServer
```

## Fallen (teuer erkauft – nicht erneut hineinlaufen)
- **Mail-Relay nie auf `127.0.0.1`.** MailRelay nimmt reines IPv4-Loopback nur
  einmal pro Idle-Phase an (Bundle-Bug des Relays). Default ist daher `::1`;
  `192.168.2.1` geht auch. Die Schwesterprojekte haben `127.0.0.1` als
  Code-Default und werden zur Laufzeit umkonfiguriert – hier nicht nachbauen.
- **Keine Top-Level-`var` in `main.swift`.** Dortige globale Variablen werden in
  Quelltext-Reihenfolge als Anweisungen initialisiert (nicht lazy wie in anderen
  Dateien). `runHeadless()` läuft ganz oben, griff damit auf ein noch nicht
  initialisiertes Array zu → stiller Absturz vor dem Serverstart. Zustand, der
  den Start überlebt, gehört in eine `static` Property (die ist lazy).
- **Menüleisten-Icon: 14 pt.** Nicht an die 22 pt der Python-Apps angleichen –
  dort skaliert rumps danach auf 20×20 herunter, nativ in AppKit landet die
  Punktgröße ungebremst in der Menüleiste und wird viel zu groß.

## Bekannte Grenzen / sinnvolle Ausbaustufen
1. **Port 123 braucht Root.** ✅ Umgesetzt: Daemon-Installation direkt aus der
   App (`DaemonControl`, einmaliger Admin-Prompt). Der Daemon ist der einzige
   Server; der Port ist frei konfigurierbar und fließt in die Plist.
2. **Stratum/Refid.** ✅ Aus dem Kernel-Sync-Status abgeleitet (`ntp_adjtime`
   via `Sources/CNTPSync`): synchron → LI=0, Stratum 2, refid "LOCL"; sonst
   LI=3 (Alarm), Stratum 16, refid 0, damit Clients die Zeit verwerfen.
   (Live testbar nur der synchrone Fall, da die Test-Maschine synchron ist.)
3. **Korrektheit der Zeitstempel** – verifiziert gegen einen eigenen UDP-Client:
   Originate-Echo, Receive-/Transmit-Felder korrekt; mode=4, stratum=2, refid=LOCL.
   (macOS-`sntp` taugt mangels Port-Syntax nicht zum Test, siehe README.)
4. **Beim Anmelden öffnen.** ✅ Menüpunkt via `SMAppService.mainApp`.
   **Logviewer.** ✅ Menüpunkt „Log anzeigen…" (App-Ereignisse + Daemon-Log).
   Offen: Signierung/Notarisierung, Zugriffs-ACL (Subnetz-Restriktion).
5. **Benachrichtigung bei Stopp/Crash.** ✅ Als **E-Mail auf Daemon-Ebene** (b)
   umgesetzt, wirkt also auch bei geschlossener Steuer-App. Ein abgestürzter
   Prozess kann nicht über sich selbst berichten, daher indirekt über einen
   Marker (`CrashMarker`, `/usr/local/var/ntpserver.state`): beim Start gesetzt,
   bei sauberem SIGTERM entfernt. Liegt er beim Start noch da, endete der Vorlauf
   unsauber (Absturz oder harter Shutdown) → `launchd` hat per `KeepAlive` neu
   gestartet → Mail. **Manueller Stopp löst bewusst keine Mail aus** (Konvention
   wie evcc). Versand per Klartext-SMTP an das lokale MailRelay (`MailNotifier`,
   POSIX-Sockets, keine Abhängigkeit); Auth/TLS/Retry macht das Relay.
   Konfiguration im Menü („Absturz-Mail…"), liegt in `UserDefaults` und reist
   über die Plist-Env (`NTP_MAIL_HOST/_PORT/_FROM/_TO`) zum Daemon – **Adressen
   gehören nicht in den Code**. Leerer Empfänger = aus. „Test-Mail senden" prüft
   die Strecke ohne echten Absturz.
   Offen: (a) lokale macOS-Notification bei „läuft→gestoppt" (das 5-s-Polling der
   Steuer-App liefert den Wechsel bereits).

## Stil & Konventionen
- Deutsch in UI und Kommentaren. Direkt, knapp, keine unnötigen Abhängigkeiten.
- **Neutrale Bezeichner – keine Personennamen** in Code, IDs, Dateinamen oder
  Doku. Schema: `app.ntpserver` (Daemon-Label `app.ntpserver.daemon`, Binary
  `/usr/local/libexec/ntpserver`). Bei neuen Identifiern fortführen.
