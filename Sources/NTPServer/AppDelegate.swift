import AppKit
import ServiceManagement

// Reine Steuer-App (Menüleiste) für den root-NTP-Daemon. Es gibt nur EINEN
// Server – den Daemon. Diese App installiert/aktiviert, deaktiviert,
// konfiguriert den Port und zeigt Status/Log.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var iconStopped: NSImage?   // Outline – Dienst gestoppt
    private var iconRunning: NSImage?   // gefüllt – Dienst läuft

    private var port: UInt16 = Config.defaultPort
    private let portKey = "ntpPort"

    private var logController: LogWindowController?
    private var appLog: [String] = []          // Steuer-Ereignisse (Ring, gekappt)
    private let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private enum Tag {
        static let toggle = 1, port = 2, login = 21, log = 30, status = 99
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let saved = UserDefaults.standard.object(forKey: portKey) as? Int,
           let p = UInt16(exactly: saved) {
            port = p
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupStatusIcon()
        buildMenu()
        updateUI()
        log("Steuer-App gestartet")
    }

    // Monochrome Menüleisten-Icons (SF-Symbole, passen sich hell/dunkel an):
    // Outline = gestoppt, gefüllt = läuft. Tatsächliche Auswahl in updateUI().
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
        menu.addItem(.separator())

        disabledItem(menu, "Server: aus", tag: Tag.status)
        menu.addItem(.separator())

        addItem(menu, "Beim Anmelden öffnen", #selector(toggleLoginItem), tag: Tag.login)
        addItem(menu, "Log anzeigen…", #selector(showLog), tag: Tag.log, key: "l")
        menu.addItem(.separator())

        addItem(menu, "Beenden", #selector(quit), key: "q")
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
        if let icon = (running ? iconRunning : iconStopped) ?? iconStopped {
            statusItem.button?.image = icon
        }
        statusItem.button?.toolTip = running ? "NTP-Server läuft" : "NTP-Server gestoppt"
        guard let menu = statusItem.menu else { return }

        menu.item(withTag: Tag.toggle)?.title = installed ? "Server deaktivieren" : "Server aktivieren"
        menu.item(withTag: Tag.port)?.title = "Port ändern… (aktuell: \(port))"
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

    // MARK: - Server (= Daemon) aktivieren/deaktivieren

    @objc private func toggleServer() {
        if DaemonControl.isInstalled {
            if DaemonControl.uninstall(onError: { [weak self] in self?.showError($0) }) {
                log("Server deaktiviert (Daemon entfernt)")
            }
        } else {
            if DaemonControl.install(port: port, onError: { [weak self] in self?.showError($0) }) {
                log("Server aktiviert (Daemon läuft als root auf UDP \(port))")
            }
        }
        updateUI()
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
        if DaemonControl.isInstalled {
            if DaemonControl.install(port: port, onError: { [weak self] in self?.showError($0) }) {
                log("Daemon mit Port \(p) neu installiert")
            }
        }
        updateUI()
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
