import Foundation

// Zentrale Namen/Pfade – von Menü-App und Daemon gemeinsam genutzt.
enum Config {
    static let appName        = "NTPServer"
    static let bundleID       = "app.ntpserver"
    static let daemonLabel    = "app.ntpserver.daemon"
    static let daemonPlist     = "/Library/LaunchDaemons/\(daemonLabel).plist"
    static let daemonBinary    = "/usr/local/libexec/ntpserver"
    static let logPath         = "/var/log/ntpserver.log"
    static let defaultPort: UInt16 = 123   // echter NTP-Port; frei konfigurierbar

    // LaunchDaemon-Plist (root, headless) – zur Laufzeit mit dem konfigurierten
    // Port erzeugt, damit die App ohne externe Dateien auskommt.
    static func daemonPlistXML(port: UInt16) -> String {
        """
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
                <key>NTP_PORT</key><string>\(port)</string>
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
}
