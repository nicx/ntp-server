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
```

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
5. **Benachrichtigung bei Stopp/Crash.** Offen. Aktuell gibt es **keine**
   E-Mail/Notification – ein Crash wird von `launchd` (`KeepAlive`) still neu
   gestartet, nur im Log sichtbar. Angedacht: (a) lokale macOS-Notification, wenn
   die Steuer-App per Timer einen Statuswechsel „läuft→gestoppt" erkennt (nur bei
   geöffneter App); (b) E-Mail auf Daemon-Ebene – braucht eingerichteten
   Mailversand (`msmtp`/`sendmail` + SMTP-Zugang), auf macOS nicht vorhanden.

## Stil & Konventionen
- Deutsch in UI und Kommentaren. Direkt, knapp, keine unnötigen Abhängigkeiten.
- **Neutrale Bezeichner – keine Personennamen** in Code, IDs, Dateinamen oder
  Doku. Schema: `app.ntpserver` (Daemon-Label `app.ntpserver.daemon`, Binary
  `/usr/local/libexec/ntpserver`). Bei neuen Identifiern fortführen.
