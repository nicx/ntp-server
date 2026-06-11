import AppKit

// Installiert/entfernt den root-LaunchDaemon direkt aus der App heraus.
// Die privilegierten Schritte laufen über einen einmaligen Admin-Prompt
// (osascript „with administrator privileges"); kein sudo im Terminal nötig.
enum DaemonControl {

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Config.daemonPlist)
    }

    // Port, mit dem der Daemon tatsächlich installiert ist (aus der Plist gelesen).
    static var installedPort: UInt16? {
        guard let data = FileManager.default.contents(atPath: Config.daemonPlist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any],
              let env = dict["EnvironmentVariables"] as? [String: Any],
              let s = env["NTP_PORT"] as? String,
              let p = UInt16(s) else { return nil }
        return p
    }

    // Läuft der Daemon-Prozess? (best effort, ohne root)
    static var isRunning: Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", Config.daemonBinary]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return isInstalled   // Fallback: installiert ⇒ vermutlich aktiv
        }
    }

    @discardableResult
    static func install(port: UInt16, onError: (String) -> Void) -> Bool {
        guard let exe = Bundle.main.executablePath else {
            onError("Programm-Binary nicht gefunden."); return false
        }
        let tmpPlist  = NSTemporaryDirectory() + "\(Config.daemonLabel).plist"
        let tmpScript = NSTemporaryDirectory() + "ntpserver-install.sh"
        let script = """
        #!/bin/sh
        set -e
        mkdir -p /usr/local/libexec
        cp '\(exe)' '\(Config.daemonBinary)'
        chmod 755 '\(Config.daemonBinary)'
        cp '\(tmpPlist)' '\(Config.daemonPlist)'
        chown root:wheel '\(Config.daemonPlist)'
        chmod 644 '\(Config.daemonPlist)'
        launchctl bootout system '\(Config.daemonPlist)' 2>/dev/null || true
        launchctl bootstrap system '\(Config.daemonPlist)'
        launchctl enable system/\(Config.daemonLabel)
        """
        do {
            try Config.daemonPlistXML(port: port).write(toFile: tmpPlist, atomically: true, encoding: .utf8)
            try script.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        } catch {
            onError("Vorbereitung fehlgeschlagen: \(error.localizedDescription)"); return false
        }
        return runPrivileged(scriptPath: tmpScript, onError: onError)
    }

    @discardableResult
    static func uninstall(onError: (String) -> Void) -> Bool {
        let tmpScript = NSTemporaryDirectory() + "ntpserver-uninstall.sh"
        let script = """
        #!/bin/sh
        launchctl bootout system '\(Config.daemonPlist)' 2>/dev/null || true
        rm -f '\(Config.daemonPlist)' '\(Config.daemonBinary)'
        """
        do { try script.write(toFile: tmpScript, atomically: true, encoding: .utf8) }
        catch { onError("Vorbereitung fehlgeschlagen: \(error.localizedDescription)"); return false }
        return runPrivileged(scriptPath: tmpScript, onError: onError)
    }

    // Führt ein Shell-Skript als root aus. Liefert false bei Fehler/Abbruch.
    private static func runPrivileged(scriptPath: String, onError: (String) -> Void) -> Bool {
        let src = "do shell script \"/bin/sh -- '\(scriptPath)'\" with administrator privileges"
        guard let apple = NSAppleScript(source: src) else {
            onError("AppleScript konnte nicht erstellt werden."); return false
        }
        var errInfo: NSDictionary?
        apple.executeAndReturnError(&errInfo)
        if let err = errInfo {
            let num = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if num == -128 { return false }   // Benutzer hat den Prompt abgebrochen
            let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "\(err)"
            onError(msg)
            return false
        }
        return true
    }
}
