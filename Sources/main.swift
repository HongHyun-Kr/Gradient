// Gradient — macOS app wrapper around the single-file web app (web/index.html).
// © 2026 HongHyun-kr · MIT License
// Build: ./build.sh  (Command Line Tools only, no Xcode needed)

import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {

    var window: NSWindow!
    var web: WKWebView!
    private let fm = FileManager.default
    private var quitting = false
    private var replied = false

    // ~/Library/Application Support/Gradient
    private lazy var supportDir: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gradient", isDirectory: true)
        try? fm.createDirectory(at: base.appendingPathComponent("backups", isDirectory: true),
                                withIntermediateDirectories: true)
        return base
    }()
    private var dataURL: URL { supportDir.appendingPathComponent("data.json") }
    private var backupDir: URL { supportDir.appendingPathComponent("backups", isDirectory: true) }

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let ucc = WKUserContentController()
        ucc.add(self, name: "gradient")
        let saved = (try? String(contentsOf: dataURL, encoding: .utf8)) ?? ""
        let payload = isValidJSON(saved) ? saved : "null"
        let boot = "window.__GRADIENT_NATIVE__ = { version: 1, data: \(payload) };"
        ucc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let cfg = WKWebViewConfiguration()
        cfg.userContentController = ucc
        cfg.websiteDataStore = .default()

        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Gradient"
        window.minSize = NSSize(width: 420, height: 520)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("GradientMainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            let a = NSAlert(); a.messageText = "web/index.html not found"; a.runModal(); NSApp.terminate(nil); return
        }
        web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Give the page a moment to flush its last edit to disk before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting || web == nil { return .terminateNow }
        quitting = true
        web.evaluateJavaScript("window.__flushSave ? (window.__flushSave(), 1) : 0") { [weak self] result, _ in
            if (result as? Int) != 1 { self?.finishQuit() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finishQuit() }
        return .terminateLater
    }

    private func finishQuit() {
        guard quitting, !replied else { return }
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: JS bridge

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "save":
            if let json = body["json"] as? String { writeData(json) }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "export":
            if let text = body["text"] as? String { exportFile(name: body["name"] as? String ?? "gradient.txt", text: text) }
        case "reveal":
            revealData()
        case "flushed":
            finishQuit()
        default:
            break
        }
    }

    private func writeData(_ json: String) {
        guard isValidJSON(json) else { return }
        do {
            try json.write(to: dataURL, atomically: true, encoding: .utf8)
            dailyBackup(json)
        } catch {
            NSLog("Gradient save failed: \(error)")
        }
    }

    // One copy per day in backups/, keep the latest 30.
    private func dailyBackup(_ json: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        let file = backupDir.appendingPathComponent("gradient-\(f.string(from: Date())).json")
        if !fm.fileExists(atPath: file.path) {
            try? json.write(to: file, atomically: true, encoding: .utf8)
            let all = ((try? fm.contentsOfDirectory(atPath: backupDir.path)) ?? [])
                .filter { $0.hasPrefix("gradient-") && $0.hasSuffix(".json") }.sorted()
            for old in all.dropLast(30) { try? fm.removeItem(at: backupDir.appendingPathComponent(old)) }
        }
    }

    private func exportFile(name: String, text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { let a = NSAlert(); a.messageText = "Couldn't save the file"; a.informativeText = error.localizedDescription; a.runModal() }
        }
    }

    @objc func revealData() {
        if fm.fileExists(atPath: dataURL.path) { NSWorkspace.shared.activateFileViewerSelecting([dataURL]) }
        else { NSWorkspace.shared.open(supportDir) }
    }

    private func isValidJSON(_ s: String) -> Bool {
        guard !s.isEmpty, let d = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) != nil
    }

    // MARK: file inputs (backup restore, AI plan import)

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { resp in completionHandler(resp == .OK ? panel.urls : nil) }
    }

    // External links open in the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? ""),
           action.navigationType == .linkActivated || action.targetFrame == nil {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: menu

    @objc func reloadPage() { web.reload() }
    @objc func zoomIn() { web.pageZoom = min(web.pageZoom + 0.1, 2.0) }
    @objc func zoomOut() { web.pageZoom = max(web.pageZoom - 0.1, 0.6) }
    @objc func zoomReset() { web.pageZoom = 1.0 }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Gradient", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Open Data Folder", action: #selector(revealData), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Gradient", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Gradient", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        // Undo/Redo stay with the page (it handles ⌘Z itself).
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
