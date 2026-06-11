import AppKit

// Einfaches Log-Fenster: zeigt App-Ereignisse und – falls vorhanden – das
// Daemon-Logfile. Aktualisiert sich alle 2 s, solange das Fenster offen ist.
final class LogWindowController: NSWindowController, NSWindowDelegate {

    private var textView: NSTextView!
    private var timer: Timer?
    var provider: (() -> String)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(Config.appName) – Log"
        window.center()
        self.init(window: window)
        window.delegate = self

        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = tv

        window.contentView?.addSubview(scroll)
        self.textView = tv
    }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let text = provider?() ?? ""
        guard textView.string != text else { return }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
