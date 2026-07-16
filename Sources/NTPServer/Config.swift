import Foundation

// Zentrale Namen/Pfade – von Menü-App und Daemon gemeinsam genutzt.
enum Config {
    static let appName        = "NTPServer"
    static let bundleID       = "app.ntpserver"
    static let daemonLabel    = "app.ntpserver.daemon"
    static let daemonPlist     = "/Library/LaunchDaemons/\(daemonLabel).plist"
    static let daemonBinary    = "/usr/local/libexec/ntpserver"
    static let logPath         = "/var/log/ntpserver.log"
    // Marker für die Absturzerkennung – überlebt Reboots, siehe CrashMarker.
    // Über NTP_STATE_PATH überschreibbar, sonst ließe sich der Headless-Modus
    // nur als root testen (der Default liegt unter /usr/local).
    static var statePath: String {
        ProcessInfo.processInfo.environment["NTP_STATE_PATH"] ?? "/usr/local/var/ntpserver.state"
    }
    static let defaultPort: UInt16 = 123   // echter NTP-Port; frei konfigurierbar

    // LaunchDaemon-Plist (root, headless) – zur Laufzeit mit dem konfigurierten
    // Port erzeugt, damit die App ohne externe Dateien auskommt. Die
    // Mail-Konfiguration reist über dieselbe Env; ohne Empfänger bleibt sie weg.
    static func daemonPlistXML(port: UInt16, mail: MailConfig) -> String {
        var mailEnv = ""
        if mail.isConfigured {
            mailEnv = """
            \n        <key>NTP_MAIL_HOST</key><string>\(xml(mail.host))</string>
                    <key>NTP_MAIL_PORT</key><string>\(mail.port)</string>
                    <key>NTP_MAIL_FROM</key><string>\(xml(mail.sender))</string>
                    <key>NTP_MAIL_TO</key><string>\(xml(mail.recipient))</string>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array><string>\(daemonBinary)</string></array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>NTP_HEADLESS</key><string>1</string>
                <key>NTP_PORT</key><string>\(port)</string>\(mailEnv)
            </dict>
            <key>UserName</key><string>root</string>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>StandardOutPath</key><string>\(logPath)</string>
            <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    // Mail-Adressen sind frei eingegeben und landen in XML – maskieren, sonst
    // zerlegt ein "&" oder "<" die Plist.
    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
