import AppKit
import ServiceManagement
import UserNotifications

// Reine Steuer-App (Menüleiste) für den root-NTP-Daemon. Es gibt nur EINEN
// Server – den Daemon. Diese App installiert/aktiviert, deaktiviert,
// konfiguriert den Port und zeigt Status/Log.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var iconStopped: NSImage?   // Outline – Dienst gestoppt
    private var iconRunning: NSImage?   // gefüllt – Dienst läuft

    private var port: UInt16 = Config.defaultPort
    private let portKey = "ntpPort"

    // Mail-Konfiguration liegt in UserDefaults und reist von dort über die Plist
    // zum Daemon. Adressen sind Laufzeitdaten und gehören nicht in den Code.
    private var mail = MailConfig(host: MailConfig.defaultHost, port: MailConfig.defaultPort,
                                  sender: "", recipient: "")
    private enum MailKey {
        static let host = "mailHost", port = "mailPort", from = "mailFrom", to = "mailTo"
    }

    private var statusTimer: Timer?            // pollt den Daemon-Zustand fürs Icon
    private var lastKnownRunning = false       // für die "läuft→gestoppt"-Erkennung
    private var suppressNextStopNotification = false   // bei gewollter Deaktivierung/Neustart

    private var logController: LogWindowController?
    private var appLog: [String] = []          // Steuer-Ereignisse (Ring, gekappt)
    private let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private enum Tag {
        static let toggle = 1, port = 2, mail = 10, mailTest = 11, login = 21, log = 30, status = 99
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let saved = UserDefaults.standard.object(forKey: portKey) as? Int,
           let p = UInt16(exactly: saved) {
            port = p
        }
        loadMailConfig()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupStatusIcon()
        buildMenu()
        requestNotificationAuthorization()
        lastKnownRunning = DaemonControl.isInstalled && DaemonControl.isRunning   // Startzustand ist kein "Wechsel"
        updateUI()
        startStatusPolling()
        log("Steuer-App gestartet")
    }

    // Ohne Erlaubnis liefert UNUserNotificationCenter später still gar nichts aus.
    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error {
                self?.log("Notification-Erlaubnis nicht erteilt: \(error.localizedDescription)")
            }
        }
    }

    // Der Daemon kann sich ohne Zutun der App ändern (Boot, Crash, launchctl von
    // Hand). Ohne Polling bliebe das Menüleisten-Icon auf dem Stand vom App-Start.
    private func startStatusPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }

    // Monochrome Menüleisten-Icons (SF-Symbole, passen sich hell/dunkel an):
    // Outline = gestoppt, gefüllt = läuft. Tatsächliche Auswahl in updateUI().
    // 14 pt ist bewusst kleiner als die 22 pt der Python-Apps (evcc, icloud-sync,
    // MailRelay): dort skaliert rumps das Bild danach noch auf 20×20 herunter,
    // hier geht die Punktgröße ungebremst in die Menüleiste.
    private func setupStatusIcon() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconStopped = symbolImage("clock", cfg)        // Outline
        iconRunning = symbolImage("clock.fill", cfg)   // gefüllt/inline
        statusItem.button?.imagePosition = .imageOnly
        if iconStopped == nil { statusItem.button?.title = Config.appName }  // Fallback
    }

    private func symbolImage(_ name: String, _ cfg: NSImage.SymbolConfiguration) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: "NTP Server")?
            .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true   // monochrom, invertiert korrekt bei Menü-Auswahl
        return img
    }

    // MARK: - Menü

    private func buildMenu() {
        let menu = NSMenu()

        addItem(menu, "Server aktivieren", #selector(toggleServer), tag: Tag.toggle, key: "s")
        addItem(menu, "Port ändern…", #selector(changePort), tag: Tag.port, key: "p")
        addItem(menu, "Absturz-Mail…", #selector(changeMail), tag: Tag.mail, key: "m")
        addItem(menu, "Test-Mail senden", #selector(sendTestMail), tag: Tag.mailTest)
        menu.addItem(.separator())

        disabledItem(menu, "Server: aus", tag: Tag.status)
        menu.addItem(.separator())

        addItem(menu, "Beim Anmelden öffnen", #selector(toggleLoginItem), tag: Tag.login)
        addItem(menu, "Log anzeigen…", #selector(showLog), tag: Tag.log, key: "l")
        menu.addItem(.separator())

        addItem(menu, "Beenden", #selector(quit), key: "q")
        menu.delegate = self   // Zustand beim Aufklappen frisch prüfen
        statusItem.menu = menu
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, tag: Int = 0, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        menu.addItem(item)
        return item
    }

    private func disabledItem(_ menu: NSMenu, _ title: String, tag: Int) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.tag = tag
        menu.addItem(item)
    }

    private func updateUI() {
        let installed = DaemonControl.isInstalled
        let running = installed && DaemonControl.isRunning

        // "läuft→gestoppt", nur passiv über den Timer/das Menü erkannt (nicht
        // beim eigenen Klick auf "Server deaktivieren" oder bei einer
        // Neuinstallation, die den Daemon kurz durchstartet – siehe
        // suppressNextStopNotification an den jeweiligen Aufrufstellen).
        if Self.shouldNotifyStop(wasRunning: lastKnownRunning, isRunning: running, suppressed: suppressNextStopNotification) {
            notifyUnexpectedStop()
        }
        suppressNextStopNotification = false
        lastKnownRunning = running

        if let icon = (running ? iconRunning : iconStopped) ?? iconStopped {
            statusItem.button?.image = icon
        }
        statusItem.button?.toolTip = running ? "NTP-Server läuft" : "NTP-Server gestoppt"
        guard let menu = statusItem.menu else { return }

        menu.item(withTag: Tag.toggle)?.title = installed ? "Server deaktivieren" : "Server aktivieren"
        menu.item(withTag: Tag.port)?.title = "Port ändern… (aktuell: \(port))"
        menu.item(withTag: Tag.mail)?.title = mail.isConfigured
            ? "Absturz-Mail… (an: \(mail.recipient))"
            : "Absturz-Mail… (aus)"
        menu.item(withTag: Tag.mailTest)?.isEnabled = mail.isConfigured
        menu.item(withTag: Tag.login)?.state = loginItemEnabled() ? .on : .off

        if let status = menu.item(withTag: Tag.status) {
            if installed {
                let installedPort = DaemonControl.installedPort
                let portStr = installedPort.map(String.init) ?? "?"
                var title = running
                    ? "Server: aktiv (UDP \(portStr), root)"
                    : "Server: installiert, läuft nicht (UDP \(portStr))"
                if let ip = installedPort, ip != port {
                    title += " – konfiguriert: \(port), Neuinstallation übernimmt"
                }
                status.title = title
            } else {
                status.title = "Server: aus"
            }
        }
    }

    // Reine Entscheidungslogik, losgelöst von AppKit – so ohne laufende App und
    // ohne Daemon-Zugriff gegen alle vier Zustandsübergänge testbar.
    static func shouldNotifyStop(wasRunning: Bool, isRunning: Bool, suppressed: Bool) -> Bool {
        wasRunning && !isRunning && !suppressed
    }

    // Nur der Hinweis am Mac; die Mail (siehe CrashMarker/MailNotifier) wirkt
    // unabhängig davon auch bei geschlossener App.
    private func notifyUnexpectedStop() {
        log("Unerwarteter Stopp erkannt")
        let content = UNMutableNotificationContent()
        content.title = Config.appName
        content.body = "Der NTP-Server ist unerwartet gestoppt."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.log("Notification konnte nicht angezeigt werden: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Server (= Daemon) aktivieren/deaktivieren

    @objc private func toggleServer() {
        if DaemonControl.isInstalled {
            suppressNextStopNotification = true   // gewollte Deaktivierung, kein "unerwartet"
            if DaemonControl.uninstall(onError: { [weak self] in self?.showError($0) }) {
                log("Server deaktiviert (Daemon entfernt)")
            }
        } else {
            if DaemonControl.install(port: port, mail: mail, onError: { [weak self] in self?.showError($0) }) {
                log("Server aktiviert (Daemon läuft als root auf UDP \(port))")
            }
        }
        updateUI()
        refreshSoon()
    }

    // `launchctl bootstrap` kehrt zurück, bevor der Daemon-Prozess läuft – ein
    // sofortiges pgrep liefe ins Leere. Kurz danach noch einmal nachsehen,
    // damit das Icon nicht bis zum nächsten Timer-Tick falsch steht.
    private func refreshSoon() {
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateUI() }
        }
    }

    // MARK: - Port konfigurieren

    @objc private func changePort() {
        let alert = NSAlert()
        alert.messageText = "Port konfigurieren"
        alert.informativeText = "UDP-Port für den NTP-Server (1–65535). Standard ist 123 "
            + "(der Port, den echte NTP-Clients erwarten). Der Server läuft als root, "
            + "daher sind auch Ports < 1024 möglich."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(port)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let p = UInt16(input), p >= 1 else {
            showError("Ungültiger Port: \(input) — erlaubt sind 1–65535.")
            return
        }
        setPort(p)
    }

    private func setPort(_ p: UInt16) {
        guard p != port else { return }
        port = p
        UserDefaults.standard.set(Int(p), forKey: portKey)
        log("Port auf \(p) gesetzt")

        // Bei aktivem Daemon sofort mit neuem Port neu installieren (ein Prompt).
        // Reinstallation durchstartet den Daemon kurz – kein "unerwarteter Stopp".
        if DaemonControl.isInstalled {
            suppressNextStopNotification = true
            if DaemonControl.install(port: port, mail: mail, onError: { [weak self] in self?.showError($0) }) {
                log("Daemon mit Port \(p) neu installiert")
            }
            refreshSoon()
        }
        updateUI()
    }

    // MARK: - Absturz-Mail

    private func loadMailConfig() {
        let d = UserDefaults.standard
        mail.host = d.string(forKey: MailKey.host).flatMap { $0.isEmpty ? nil : $0 } ?? MailConfig.defaultHost
        mail.port = (d.object(forKey: MailKey.port) as? Int).flatMap(UInt16.init(exactly:)) ?? MailConfig.defaultPort
        mail.sender = d.string(forKey: MailKey.from) ?? ""
        mail.recipient = d.string(forKey: MailKey.to) ?? ""
    }

    private func saveMailConfig() {
        let d = UserDefaults.standard
        d.set(mail.host, forKey: MailKey.host)
        d.set(Int(mail.port), forKey: MailKey.port)
        d.set(mail.sender, forKey: MailKey.from)
        d.set(mail.recipient, forKey: MailKey.to)
    }

    @objc private func changeMail() {
        let alert = NSAlert()
        alert.messageText = "Absturz-Mail"
        alert.informativeText = "Meldet einen unerwarteten Neustart des Daemons per E-Mail. "
            + "Ein manueller Stopp löst bewusst keine Mail aus.\n\n"
            + "Versand über das lokale Relay ohne Auth/TLS. Leerer Empfänger schaltet ab."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")

        let fields = [("Empfänger:", mail.recipient), ("Absender:", mail.sender),
                      ("Relay-Host:", mail.host), ("Relay-Port:", String(mail.port))]
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        var inputs: [NSTextField] = []
        for (label, value) in fields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let caption = NSTextField(labelWithString: label)
            caption.alignment = .right
            caption.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let input = NSTextField(string: value)
            input.widthAnchor.constraint(equalToConstant: 220).isActive = true
            row.addArrangedSubview(caption)
            row.addArrangedSubview(input)
            grid.addArrangedSubview(row)
            inputs.append(input)
        }
        grid.frame = NSRect(x: 0, y: 0, width: 310, height: 4 * 28)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = inputs.first

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let recipient = inputs[0].stringValue.trimmingCharacters(in: .whitespaces)
        let sender = inputs[1].stringValue.trimmingCharacters(in: .whitespaces)
        let host = inputs[2].stringValue.trimmingCharacters(in: .whitespaces)
        let portText = inputs[3].stringValue.trimmingCharacters(in: .whitespaces)
        guard let relayPort = UInt16(portText), relayPort >= 1 else {
            showError("Ungültiger Relay-Port: \(portText) — erlaubt sind 1–65535.")
            return
        }
        // Kein Empfänger ⇒ Versand aus; sonst braucht das Relay auch einen Absender.
        if !recipient.isEmpty && sender.isEmpty {
            showError("Ohne Absender nimmt das Relay die Mail nicht an.")
            return
        }
        let old = mail
        mail = MailConfig(host: host.isEmpty ? MailConfig.defaultHost : host,
                          port: relayPort, sender: sender, recipient: recipient)
        saveMailConfig()
        log(mail.isConfigured ? "Absturz-Mail an \(recipient) über \(mail.host):\(relayPort)"
                              : "Absturz-Mail deaktiviert")

        // Die Konfiguration steckt in der Plist – der Daemon sieht Änderungen
        // erst nach Neuinstallation.
        let changed = old.host != mail.host || old.port != mail.port
            || old.sender != mail.sender || old.recipient != mail.recipient
        if changed && DaemonControl.isInstalled {
            suppressNextStopNotification = true   // Reinstallation, kein "unerwartet"
            if DaemonControl.install(port: port, mail: mail, onError: { [weak self] in self?.showError($0) }) {
                log("Daemon mit neuer Mail-Konfiguration neu installiert")
            }
            refreshSoon()
        }
        updateUI()
    }

    @objc private func sendTestMail() {
        guard mail.isConfigured else {
            showError("Erst unter „Absturz-Mail…\" Empfänger und Absender eintragen.")
            return
        }
        let cfg = mail
        let body = """
        Test der Absturz-Benachrichtigung des NTP-Servers.

        Kommt diese Mail an, erreicht auch die echte Absturzmeldung ihr Ziel.
        Sie wird von der Steuer-App verschickt; im Ernstfall verschickt sie der
        Daemon selbst über dieselbe Konfiguration.

        Relay:     \(cfg.host):\(cfg.port)
        Zeitpunkt: \(ISO8601DateFormatter().string(from: Date()))
        """
        log("Test-Mail an \(cfg.recipient) über \(cfg.host):\(cfg.port)…")
        // Nebenläufig: ein totes Relay würde die Menüleiste sonst einfrieren.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = MailNotifier.send(cfg, subject: "NTP-Server: Test-Mail", body: body)
            DispatchQueue.main.async {
                guard let self else { return }
                if let err {
                    self.showError("Test-Mail fehlgeschlagen: \(err)")
                } else {
                    self.log("Test-Mail zugestellt")
                    let ok = NSAlert()
                    ok.messageText = Config.appName
                    ok.informativeText = "Test-Mail an \(cfg.recipient) zugestellt."
                    ok.runModal()
                }
            }
        }
    }

    // MARK: - Beim Anmelden öffnen (betrifft die Steuer-App)

    private func loginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log("Login-Item deaktiviert")
            } else {
                try SMAppService.mainApp.register()
                log("Login-Item aktiviert")
            }
        } catch {
            showError("Login-Item: \(error.localizedDescription)")
        }
        updateUI()
    }

    // MARK: - Log

    @objc private func showLog() {
        if logController == nil {
            let c = LogWindowController()
            c.provider = { [weak self] in self?.buildLogText() ?? "" }
            logController = c
        }
        logController?.show()
    }

    private func log(_ message: String) {
        appLog.append("\(logFormatter.string(from: Date()))  \(message)")
        if appLog.count > 500 { appLog.removeFirst(appLog.count - 500) }
        logController?.refresh()
    }

    private func buildLogText() -> String {
        var out = "── Steuer-App ──\n"
        out += appLog.isEmpty ? "(keine)\n" : appLog.joined(separator: "\n") + "\n"
        out += "\n── Daemon-Log (\(Config.logPath)) ──\n"
        if let data = FileManager.default.contents(atPath: Config.logPath),
           let text = String(data: data, encoding: .utf8) {
            out += text.isEmpty ? "(leer)\n" : text
        } else {
            out += "(kein Daemon-Log – Server nicht aktiviert oder Datei nicht lesbar)\n"
        }
        return out
    }

    // MARK: - Helfer

    private func showError(_ message: String) {
        log("Fehler: \(message)")
        let alert = NSAlert()
        alert.messageText = Config.appName
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quit() {
        // Beendet nur die Steuer-App; der Daemon läuft unabhängig weiter.
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateUI()
    }
}
