import AppKit
import MediaSherpaCore
import SwiftUI

/// What the help window asks the main window to do: point at a part of it,
/// and which parts are on screen now.
@MainActor
@Observable
final class HelpModel {
    /// The part outlined now, for a few seconds after Show Me.
    private(set) var showing: HelpTarget?
    /// Goes up with each Show Me, so the same part can be shown twice.
    private(set) var request = 0
    private(set) var onScreen: Set<HelpTarget> = []
    /// The Help menu's Live Tech Support… opens the help window at it.
    var supportRequested = false

    func show(_ target: HelpTarget) {
        showing = target
        request += 1
        let asked = request
        Task {
            try? await Task.sleep(for: .seconds(4))
            if request == asked { showing = nil }
        }
    }

    func appeared(_ target: HelpTarget) { onScreen.insert(target) }
    func disappeared(_ target: HelpTarget) { onScreen.remove(target) }
}

/// Marks a part of the main window that help can point at: scrolled to and
/// outlined, pulsing, when its answer's Show Me is pressed.
struct HelpSpot: ViewModifier {
    let target: HelpTarget
    @Environment(HelpModel.self) private var help

    func body(content: Content) -> some View {
        content
            .id(target)
            .overlay {
                if help.showing == target {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(-5)
                        .phaseAnimator([1.0, 0.25]) { outline, opacity in outline.opacity(opacity) }
                            animation: { _ in .easeInOut(duration: 0.45) }
                        .allowsHitTesting(false)
                }
            }
            .onAppear { help.appeared(target) }
            .onDisappear { help.disappeared(target) }
    }
}

extension View {
    func helpSpot(_ target: HelpTarget) -> some View { modifier(HelpSpot(target: target)) }
}

/// Help > Media Sherpa Help: type a few words, read the answer, and Show Me
/// points at the part of the window it's about. Live Tech Support is the
/// first row, and the menu commands the words find come before the answers,
/// to run from here (what macOS's own Help search did, without Apple's help).
struct HelpView: View {
    var settings: SettingsModel
    var watcher: CardWatcher
    @Environment(HelpModel.self) private var help
    @State private var query = ""
    @State private var opened: String?
    @State private var supporting = false
    @FocusState private var searching: Bool

    var body: some View {
        let results = Help.search(query)
        let menuItems = MenuItems.read()
        let commands = Help.search(query, in: menuItems.commands)
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search help: trash, stars in Lightroom, server light…", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($searching)
                .onChange(of: query) { opened = nil }
            Button { supporting = true } label: {
                Label("Live Tech Support", systemImage: "message.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .help("Writes to tech support in WhatsApp, with what the app knows about the problem")
            Divider()
            if !commands.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In the menus").font(.caption).foregroundStyle(.secondary)
                    ForEach(commands.prefix(5)) { command in
                        commandRow(command) { run(menuItems.items[command.id]) }
                    }
                }
                Divider()
            }
            if results.isEmpty {
                Text("No answers for \"\(query)\". Try other words, or ask Live Tech Support.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(results) { answer in
                            // Typing opens the best match; a click opens any other.
                            row(answer, open: opened == answer.id || (opened == nil && !query.isEmpty && answer.id == results.first?.id))
                        }
                    }
                }
            }
        }
        .padding(16)
        .onAppear {
            searching = true
            supporting = supporting || help.supportRequested
            help.supportRequested = false
            // Stays in front of the main window, so Show Me doesn't hide it.
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("help") == true }?.level = .floating
        }
        .onChange(of: help.supportRequested) {
            if help.supportRequested { supporting = true; help.supportRequested = false }
        }
        .sheet(isPresented: $supporting) { SupportView(settings: settings, watcher: watcher) }
    }

    private func row(_ answer: HelpAnswer, open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { opened = open ? "" : answer.id } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
                    Text(answer.question).fontWeight(open ? .semibold : .regular)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(answer.answer)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
                if let target = answer.target {
                    HStack {
                        Button("Show Me") { show(target) }
                        if !help.onScreen.contains(target) {
                            Text("Not showing right now: look for \(target.place).")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 18)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func commandRow(_ command: MenuCommand, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack {
                Image(systemName: "filemenu.and.cursorarrow").frame(width: 18)
                Text(command.title)
                Text("\(command.menu) menu").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(command.shortcut).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!command.enabled)
        .help(command.enabled ? "Does \(command.menu) › \(command.title)" : "Not available right now, as in the menu")
        .padding(.vertical, 3)
    }

    /// Runs a menu command with the main window in front, as if chosen from
    /// the menu bar there.
    private func run(_ item: NSMenuItem) {
        if watcher.grid.isViewing { watcher.grid.closeView() }
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        guard let menu = item.menu else { return }
        let index = menu.index(of: item)
        if index >= 0 { menu.performActionForItem(at: index) }
    }

    /// Brings the main window forward, out of the large view, and points.
    private func show(_ target: HelpTarget) {
        if watcher.grid.isViewing { watcher.grid.closeView() }
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        help.show(target)
    }
}

/// Live Tech Support: the photographer types what happened; the app adds
/// what it knows and the latest receipt's summary, shows it all, and opens
/// WhatsApp with it written. Sending is one more tap there.
struct SupportView: View {
    var settings: SettingsModel
    var watcher: CardWatcher
    @Environment(\.dismiss) private var dismiss
    @State private var problem = ""
    @State private var receipt: ReceiptSummary?
    @State private var lookedForReceipt = false
    @State private var opened = false

    var body: some View {
        let message = Support.message(problem: problem, details: details, receipt: receipt)
        let number = Support.number(setting: settings.settings.supportWhatsApp,
                                    built: Bundle.main.object(forInfoDictionaryKey: "MediaSherpaSupportWhatsApp") as? String)
        let link = Support.whatsAppURL(number: number, text: message)
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Tech Support").font(.title2).bold()
            Text("What happened? What were you trying to do?").foregroundStyle(.secondary)
            TextEditor(text: $problem)
                .font(.body)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.panelEdge, lineWidth: 1))
            GroupBox("Sent with it") {
                ScrollView {
                    Text(Support.message(problem: "", details: details, receipt: receipt))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                if let receipt {
                    HStack {
                        ShareReceiptButton(url: receipt.url).fixedSize()
                        Button("Show Receipt in Finder") { NSWorkspace.shared.activateFileViewerSelecting([receipt.url]) }
                    }
                    Text("A WhatsApp message can only carry text: to send the receipt itself, Share it to WhatsApp "
                         + "and pick the support chat, or drag it from Finder into the chat.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if lookedForReceipt {
                    Text("No receipt found in \(settings.settings.destinationRoot).").font(.caption).foregroundStyle(.secondary)
                }
            }
            if link == nil {
                Label("This copy of Media Sherpa was built without a support number. Put it in scripts/support-whatsapp.txt "
                      + "and run make-app.sh again (or add supportWhatsApp to the settings file).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if opened {
                Text("WhatsApp is open with the message written: press Send there. The reply comes back in WhatsApp.")
                    .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(opened ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open in WhatsApp") {
                    if let link { NSWorkspace.shared.open(link); opened = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(link == nil || problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.window)
        .task {
            let root = settings.settings.destinationRootURL
            receipt = await Task.detached(priority: .userInitiated) {
                Support.latestReceipt(under: root).flatMap { Support.summary(ofReceipt: $0) }
            }.value
            lookedForReceipt = true
        }
    }

    /// The app's version and Mac, each card and the step it's on, and the last error.
    private var details: [String] {
        let version = About.version
        var lines = ["Media Sherpa \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Settings: \(settings.fileURL.lastPathComponent)"]
        for card in watcher.cards {
            lines.append("Card \(card.info.name): " + step(watcher.copyStates[card.id]))
        }
        if watcher.cards.isEmpty { lines.append("No card in") }
        let errors = watcher.copyStates.values.compactMap { if case let .failed(message) = $0 { message } else { nil } }
            + [watcher.grid.problem, settings.errorMessage].compactMap { $0 }
        if let last = errors.last { lines.append("Error: \(last)") }
        return lines
    }

    private func step(_ state: CopyState?) -> String {
        switch state {
        case nil: "waiting for Copy"
        case .preparing: "reading capture dates"
        case let .copying(fraction): "copying, \(Int(fraction * 100))%"
        case .askTrash: "copied, asking about the Trash"
        case .clearing: "moving originals to the card's Trash"
        case .done: "done"
        case let .failed(message): "failed: \(message)"
        }
    }
}

/// The Mac's Share menu for the receipt, so it can go to WhatsApp as a file.
struct ShareReceiptButton: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share Receipt…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.url = url }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    @MainActor
    final class Coordinator: NSObject {
        var url: URL
        init(url: URL) { self.url = url }

        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

/// The commands in the app's own menus (File, Photos, Help), read from the
/// menu bar as it is now, so names like "Copy NIKON D850" and what's greyed
/// out match the menus exactly.
@MainActor
struct MenuItems {
    var commands: [MenuCommand] = []
    var items: [NSMenuItem] = []

    static let menus: Set<String> = ["File", "Photos", "Help"]

    static func read() -> MenuItems {
        var found = MenuItems()
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu, menus.contains(top.title) else { continue }
            found.add(menu, in: top.title)
        }
        return found
    }

    private mutating func add(_ menu: NSMenu, in name: String) {
        menu.update()
        for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.title.isEmpty {
            if let submenu = item.submenu { add(submenu, in: name); continue }
            let flags = item.keyEquivalentModifierMask
            commands.append(MenuCommand(id: items.count, menu: name, title: item.title,
                                        shortcut: Help.shortcut(key: item.keyEquivalent, control: flags.contains(.control),
                                                                option: flags.contains(.option), shift: flags.contains(.shift),
                                                                command: flags.contains(.command)),
                                        enabled: item.isEnabled))
            items.append(item)
        }
    }
}

/// Takes macOS's own search field out of the Help menu: it searches Apple's
/// help for the whole Mac too ("photos" finds the Photos app), which can't be
/// narrowed, so this app's help window is the one search. macOS puts the field
/// in whichever menu is the app's help menu, so that's set to one never shown,
/// and set again if the menus are rebuilt.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let neverShown = NSMenu(title: "Help")

    func applicationDidUpdate(_ notification: Notification) {
        if NSApp.helpMenu !== neverShown { NSApp.helpMenu = neverShown }
    }

    /// Loads a folder, as Load Folder… does; set once the main window is up.
    var loadFolder: ((URL) -> Void)? {
        didSet { if let url = droppedFolder { droppedFolder = nil; open(url) } }
    }
    /// A folder dropped before the main window was up, as when the drop launched the app.
    private var droppedFolder: URL?

    /// A folder dropped on the Dock icon (or opened with the app) is loaded like an
    /// earlier import. Files are ignored; with several folders the first one is loaded.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        else { return }
        open(url)
    }

    private func open(_ url: URL) {
        guard let loadFolder else { droppedFolder = url; return }
        loadFolder(url)
        NSApp.activate()
    }
}

/// The Help menu: this app's help, Live Tech Support, and a test alert for the phone.
struct HelpCommands: Commands {
    var help: HelpModel
    var license: LicenseModel
    var watcher: CardWatcher
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Media Sherpa Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
            Button("Live Tech Support…") {
                help.supportRequested = true
                openWindow(id: "help")
            }
            Divider()
            Button("Setup Tutorial…") { openWindow(id: "tutorial") }
            Button("Send Test Notification") { watcher.sendTestNotification() }
                .disabled(!watcher.notificationsOn)
            Button("License…") { openWindow(id: "license") }
        }
        CommandGroup(replacing: .appInfo) {
            Button("About CC Media Sherpa") { About.show(license: license) }
        }
    }
}
