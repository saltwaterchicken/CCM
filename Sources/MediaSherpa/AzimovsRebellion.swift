//  AzimovsRebellion.swift
//  The hidden game: Window › Azimov's Rebellion (⇧⌘G) opens it full screen, in
//  its own classic Mac OS 9 desktop. The game is Resources/azimovs-rebellion.html
//  (the photographer's, copied in unchanged), which make-app.sh puts in the app.
//  Media Sherpa feeds its status window the card copy, and saves its "Send Earth
//  a Postcard" pictures in the card folder. Built the same way as FrameDrop in
//  CC Frame Puller.

import AppKit
import MediaSherpaCore
import OSLog
import SwiftUI
import WebKit

// MARK: - Controller (one shared game)

/// Full-screen steps go to the system log, to see what macOS did:
/// log show --last 10m --predicate 'subsystem == "com.capturecampmedia.mediasherpa" && category == "game"'
private let log = Logger(subsystem: "com.capturecampmedia.mediasherpa", category: "game")

@MainActor
final class AzimovsRebellionController {
    static let shared = AzimovsRebellionController()
    /// The card copy as JSON for the game's status window; set when the app starts.
    static var status: (@MainActor () -> String)?
    /// The card folder being copied into, or the last one: where postcards go.
    static var cardFolder: (@MainActor () -> URL?)?

    let webView: WKWebView
    private let messages = AzimovsRebellionMessages()
    private var observers: [NSObjectProtocol] = []
    private var closeAfterFullScreen = false
    private var minimizeAfterFullScreen = false
    private var fullScreenTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var lastStatus = ""

    private init() {
        let config = WKWebViewConfiguration()
        // The game posts "close", "zoom" and its postcards here.
        config.userContentController.add(messages, name: "azimov")
        // Sound effects play without an extra click.
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = AzimovsRebellionWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = messages
        if let url = Bundle.main.url(forResource: "azimovs-rebellion", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // e.g. under `swift run`, which has no app bundle
            webView.loadHTMLString("<body style='font:16px -apple-system;color:#fff;background:#2a8db5;padding:24px'>"
                                   + "Azimov's Rebellion isn't in this copy of the app. Build it with scripts/make-app.sh.</body>",
                                   baseURL: nil)
        }
    }

    private func run(_ js: String) { webView.evaluateJavaScript(js, completionHandler: nil) }

    // MARK: Status window

    /// Sends the card copy to the game: at most every 0.3 s, and only when it changed.
    private func sendStatus(force: Bool = false) {
        guard let json = Self.status?() else { return }
        if !force && json == lastStatus { return }
        lastStatus = json
        run("window.AzimovsRebellion && AzimovsRebellion.setStatus(\(json))")
    }

    func pageLoaded() { sendStatus(force: true) }

    private func startStatus() {
        guard statusTimer == nil else { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { AzimovsRebellionController.shared.sendStatus() }
        }
    }

    private func stopStatus() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    // MARK: Postcards

    /// "Send Earth a Postcard": saves the game's JPEG in the card folder, then
    /// tells the game how it went ({ ok, folder } or { ok, error }).
    func savePostcard(dataURL: String, fileName: String) {
        let folder = Self.cardFolder?()
        Task.detached {
            let reply: [String: Any]
            do {
                guard let folder, FileManager.default.fileExists(atPath: folder.path) else { throw Postcard.SaveError.noFolder }
                _ = try Postcard.save(dataURL: dataURL, fileName: fileName, in: folder)
                reply = ["ok": true, "folder": folder.lastPathComponent]
            } catch {
                reply = ["ok": false, "error": error.localizedDescription]
            }
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8), as: UTF8.self)
            await MainActor.run {
                AzimovsRebellionController.shared.run("window.AzimovsRebellion && AzimovsRebellion.capturePlanetDone(\(json))")
            }
        }
    }

    // MARK: Full screen

    var window: NSWindow? { webView.window }
    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// Opens straight into full screen. Waits until the window is really open
    /// (a just-opened or reopened one isn't yet), then switches. It doesn't wait
    /// for it to be on the current Space: with Media Sherpa itself in full
    /// screen, a new window opens on another Space and never would be.
    func enterFullScreen() {
        fullScreenTask?.cancel()
        fullScreenTask = Task { @MainActor in
            for _ in 0..<40 {                       // up to 4 seconds
                if Task.isCancelled { return }
                if let window = self.window, window.isVisible, !window.isMiniaturized {
                    try? await Task.sleep(for: .milliseconds(150))   // let it finish appearing
                    if Task.isCancelled { return }
                    // Two tries: macOS can ignore the first while another window is still changing Spaces.
                    for attempt in 1...2 {
                        if window.styleMask.contains(.fullScreen) { log.info("full screen: already (try \(attempt))"); return }
                        self.allowFullScreen(window)
                        log.info("full screen: try \(attempt), \(self.describe(window), privacy: .public)")
                        window.makeKeyAndOrderFront(nil)
                        window.toggleFullScreen(nil)
                        try? await Task.sleep(for: .milliseconds(1500))
                        if Task.isCancelled { return }
                    }
                    log.info("full screen: after 2 tries \(window.styleMask.contains(.fullScreen) ? "yes" : "NO"), \(self.describe(window), privacy: .public)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            log.info("full screen: the game window never opened (window: \(self.window == nil ? "none" : "not visible", privacy: .public))")
        }
    }

    /// Its own full-screen Space: not an extra window over Media Sherpa's, which
    /// macOS won't take full screen.
    private func allowFullScreen(_ window: NSWindow) {
        window.collectionBehavior.remove([.fullScreenAuxiliary, .fullScreenNone, .fullScreenDisallowsTiling])
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    private func describe(_ window: NSWindow) -> String {
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible }
        let sherpaFull = others.contains { $0.styleMask.contains(.fullScreen) }
        return "behavior \(window.collectionBehavior.rawValue), key \(window.isKeyWindow), on this Space \(window.isOnActiveSpace), "
            + "resizable \(window.styleMask.contains(.resizable)), Media Sherpa full screen \(sherpaFull), app active \(NSApp.isActive)"
    }

    /// The zoom box: full screen in and out.
    func toggleFullScreen() {
        guard let window else { return }
        allowFullScreen(window)
        window.toggleFullScreen(nil)
    }

    /// The game's window has appeared: allow full screen, start sending the
    /// card copy, and finish closing after leaving full screen if Close was chosen.
    func attached(to window: NSWindow) {
        allowFullScreen(window)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let game = AzimovsRebellionController.shared
                    if game.closeAfterFullScreen { game.finishClosing() }
                    if game.minimizeAfterFullScreen { game.finishMinimizing() }
                }
            },
            // Back from the Dock: straight into full screen again.
            NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AzimovsRebellionController.shared.enterFullScreen() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AzimovsRebellionController.shared.stopStatus() }
            },
            // Pause when the game stops being the active window.
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AzimovsRebellionController.shared.pause() }
            },
        ]
        sendStatus(force: true)
        startStatus()
        // However it was opened (the menu, or macOS reopening it at launch), the game is full screen.
        enterFullScreen()
    }

    /// The close box, File › Close and ⌘W: pause and close the game at once. In
    /// full screen the window is hidden straight away and closed once the
    /// full-screen exit is done (or after 3 seconds if that notice never comes).
    func closeGame() {
        pause()
        fullScreenTask?.cancel()
        guard let window else { return }
        if isFullScreen {
            closeAfterFullScreen = true
            window.alphaValue = 0
            window.toggleFullScreen(nil)
            Task { @MainActor in
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !self.closeAfterFullScreen { return }
                    if !self.isFullScreen { break }
                }
                if self.closeAfterFullScreen { self.finishClosing() }
            }
        } else {
            window.close()
        }
    }

    fileprivate func finishClosing() {
        closeAfterFullScreen = false
        guard let window else { return }
        window.close()
        window.alphaValue = 1               // ready for next time
    }

    /// The desktop's CC Media Sherpa icon: the game (already paused) goes to the
    /// Dock and Media Sherpa's own window comes forward. Full screen is left first,
    /// as a full-screen window can't be minimized; then it's minimized once that's
    /// done (or after 3 seconds if that notice never comes).
    func returnToSherpa() {
        pause()
        fullScreenTask?.cancel()
        guard let window else { return }
        if isFullScreen {
            minimizeAfterFullScreen = true
            window.toggleFullScreen(nil)
            Task { @MainActor in
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !self.minimizeAfterFullScreen { return }
                    if !self.isFullScreen { break }
                }
                if self.minimizeAfterFullScreen { self.finishMinimizing() }
            }
        } else {
            finishMinimizing()
        }
    }

    fileprivate func finishMinimizing() {
        minimizeAfterFullScreen = false
        guard let game = window else { return }
        game.miniaturize(nil)
        // Media Sherpa's main window (its scene id is "main"), or any other window it has open.
        let others = NSApp.windows.filter { $0 !== game && $0.canBecomeMain && !$0.isMiniaturized }
        let main = others.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? others.first { $0.isVisible }
        NSApp.activate()
        main?.makeKeyAndOrderFront(nil)
    }

    func pause() { run("window.AzimovsRebellion && AzimovsRebellion.pause()") }
}

// MARK: - Web view that takes the keyboard, so the game's keys reach it

final class AzimovsRebellionWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
        MainActor.assumeIsolated { AzimovsRebellionController.shared.attached(to: window) }
    }
}

/// Hears the game page's messages, and when it has loaded.
final class AzimovsRebellionMessages: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { AzimovsRebellionController.shared.pageLoaded() }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["type"] as? String == "capturePlanet",
           let data = body["data"] as? String {
            let name = body["fileName"] as? String ?? "Azimovs Rebellion postcard.jpg"
            MainActor.assumeIsolated { AzimovsRebellionController.shared.savePostcard(dataURL: data, fileName: name) }
            return
        }
        switch message.body as? String {
        case "close": MainActor.assumeIsolated { AzimovsRebellionController.shared.closeGame() }
        case "zoom": MainActor.assumeIsolated { AzimovsRebellionController.shared.toggleFullScreen() }
        case "sherpa": MainActor.assumeIsolated { AzimovsRebellionController.shared.returnToSherpa() }
        default: break
        }
    }
}

struct AzimovsRebellionWebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { AzimovsRebellionController.shared.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Menu item and window

/// Window › Azimov's Rebellion (⇧⌘G). Everything else is in the game's own menu bar.
struct AzimovsRebellionCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Azimov's Rebellion") {
                openWindow(id: "azimovs-rebellion")
                AzimovsRebellionController.shared.enterFullScreen()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}

struct AzimovsRebellionScene: Scene {
    var body: some Scene {
        Window("Azimov's Rebellion", id: "azimovs-rebellion") {
            AzimovsRebellionWebViewRepresentable()
                .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 620)
                .background(Color(red: 0.165, green: 0.553, blue: 0.710)) // the desktop blue
        }
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
    }
}
