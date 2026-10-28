import AppKit
import CardIngestCore
import SwiftUI

/// The license key in use and what it allows, checked at launch and every
/// hour while the app is open. All on this Mac: no network. The key and the
/// latest date seen are kept in the app's own preferences, not the settings
/// file, which changes from project to project.
@MainActor
@Observable
final class LicenseModel {
    private(set) var status = License.Status.missing

    static let keyKey = "licenseKey"
    static let lastSeenKey = "licenseLastSeen"

    init() {
        check()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3600))
                self?.check()
            }
        }
    }

    func check(now: Date = Date()) {
        let defaults = UserDefaults.standard
        let lastSeen = defaults.object(forKey: Self.lastSeenKey) as? Date
        status = License.check(defaults.string(forKey: Self.keyKey), now: now, lastSeen: lastSeen)
        if case .clockTurnedBack = status { return }
        defaults.set(License.lastSeen(lastSeen, now: now), forKey: Self.lastSeenKey)
    }

    /// Takes a pasted key if it's valid now; otherwise keeps the one in use
    /// and returns what's wrong with the new one.
    func activate(_ key: String) -> String? {
        let now = Date()
        let lastSeen = UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date
        let checked = License.check(key, now: now, lastSeen: lastSeen)
        guard checked.isValid else { return checked.problem }
        UserDefaults.standard.set(key.filter { !$0.isWhitespace }, forKey: Self.keyKey)
        check(now: now)
        return nil
    }

    /// "Renew" from 14 days before the end, while the key still works.
    var daysLeftToRenew: Int? {
        guard case let .valid(license) = status else { return nil }
        let days = license.daysLeft(at: Date())
        return days <= License.reminderDays ? days : nil
    }

    var licensedTo: String? {
        guard case let .valid(license) = status else { return nil }
        return "Licensed to \(license.email) until \(License.format(license.expires))"
    }
}

/// Help › License…, and what opens by itself without a working key: paste
/// the key from the email and Activate.
struct LicenseView: View {
    var license: LicenseModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var key = ""
    @State private var error: String?
    @State private var entering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Card Ingest License").font(.title2).bold()
            if let licensedTo = license.licensedTo, !entering {
                Label(licensedTo, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                if let days = license.daysLeftToRenew {
                    Text(renewText(days)).foregroundStyle(.orange)
                }
                HStack {
                    Button("Enter New Key…") { entering = true }
                    Spacer()
                    Button("Done") { dismissWindow(id: "license") }.keyboardShortcut(.defaultAction)
                }
            } else {
                if let problem = license.status.problem, license.licensedTo == nil {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(license.status == .missing ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Until then, copying cards and Sync With Server are off. Photos already copied can still "
                         + "be opened and rated, and nothing on your drives is changed.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Paste the key from your email (it starts with \(License.prefix)):")
                TextEditor(text: $key)
                    .font(.body.monospaced())
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.panelEdge, lineWidth: 1))
                    .onChange(of: key) { error = nil }
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if license.licensedTo != nil { Button("Cancel") { entering = false; key = "" } }
                    Spacer()
                    Button("Activate") {
                        error = license.activate(key)
                        if error == nil { key = ""; entering = false }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.allSatisfy(\.isWhitespace))
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { license.check() }
    }

    private func renewText(_ days: Int) -> String {
        days <= 1 ? "Last day: ask for a new key to keep copying cards."
            : "Ends in \(days) days: ask for a new key to renew."
    }
}

/// A thin line across the top of the main window: a reminder to renew from
/// 14 days before the end, or why copying is off. Never blocks anything itself.
struct LicenseBanner: View {
    var license: LicenseModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let days = license.daysLeftToRenew {
            bar(days <= 1 ? "Your license ends today." : "Your license ends in \(days) days.",
                button: "Renew…", color: .orange)
        } else if !license.status.isValid {
            bar("Not licensed: copying cards and Sync With Server are off.", button: "Enter Key…", color: .red)
        }
    }

    private func bar(_ text: String, button: String, color: Color) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text)
            Spacer()
            Button(button) { openWindow(id: "license") }.controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
    }
}
