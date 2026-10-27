import CardIngestCore
import CoreWLAN
import Network
import SwiftUI

/// Whether this Mac is wired to the server before a card goes in: the backup
/// folder on a mounted network share, Wi-Fi off, and an Ethernet cable
/// connected. Only a warning: Copy works either way, and the backup catches
/// up later (photographer's call, 2026-10-27). Checked every few seconds.
@MainActor
@Observable
final class ServerStatus {
    private(set) var backup = BackupVolume.notSet
    /// Nil on a Mac with no Wi-Fi.
    private(set) var wifiOn: Bool?
    private(set) var wired = false
    /// The backup folder from the settings.
    private var folder: URL?
    private var checking = false
    private let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private var timer: Timer?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.wired = up }
        }
        monitor.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func use(_ settings: IngestSettings) {
        guard settings.backupRootURL != folder else { return }
        folder = settings.backupRootURL
        refresh()
    }

    func refresh() {
        wifiOn = CWWiFiClient.shared().interface().map { $0.powerOn() }
        // A share that has gone away can take a while to answer, so look off
        // the main thread, one look at a time.
        guard !checking else { return }
        checking = true
        let folder = folder
        Task {
            backup = await Task.detached(priority: .utility) { BackupVolume.check(folder) }.value
            checking = false
        }
    }

    /// The light only matters when the backup goes to a server (or should, and isn't there).
    var applies: Bool {
        switch backup {
        case .notSet, .localDrive: false
        case .missing, .standIn, .server: true
        }
    }

    var onServer: Bool { if case .server = backup { true } else { false } }
    var allGood: Bool { onServer && wifiOn != true && wired }
}

/// The light above the cards: green when wired to the server, red with what's wrong.
struct ServerLight: View {
    var status: ServerStatus

    var body: some View {
        if status.applies {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.allGood ? Color.green : Color.red)
                        .frame(width: 14, height: 14)
                        .shadow(color: (status.allGood ? Color.green : Color.red).opacity(0.7), radius: 4)
                    Text(status.allGood ? "Wired to the server" : "Not wired to the server")
                        .font(.headline)
                }
                HStack(spacing: 14) {
                    check(serverText, ok: status.onServer)
                    if let on = status.wifiOn { check(on ? "Wi-Fi on" : "Wi-Fi off", ok: !on) }
                    check(status.wired ? "Ethernet connected" : "No Ethernet", ok: status.wired)
                }
                .font(.caption)
                if !status.allGood {
                    Text(advice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var serverText: String {
        switch status.backup {
        case let .server(name): "Server: \(name)"
        case .standIn: "Server not mounted"
        default: "Server not mounted"
        }
    }

    private var advice: String {
        var steps: [String] = []
        switch status.backup {
        case .missing: steps.append("connect to the server in Finder (Go › Connect to Server)")
        case .standIn: steps.append("connect to the server in Finder: a folder on this Mac is standing in for it, and the backup would fill this Mac instead")
        default: break
        }
        if status.wifiOn == true { steps.append("turn Wi-Fi off so the backup goes over the cable") }
        if !status.wired { steps.append("plug in the network cable") }
        let list = steps.joined(separator: ", ")
        return "To back up to the server, \(list). You can still copy cards; the backup can catch up later with Sync With Server."
    }

    private func check(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.red)
    }
}
