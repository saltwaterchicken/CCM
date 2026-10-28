import AppKit

/// Card Ingest › About Card Ingest: the logo (the app's icon), the version,
/// Capture Camp Media's details, and who the app is licensed to.
@MainActor
enum About {
    static let company = "Capture Camp Media"
    static let website = URL(string: "https://www.capturecampmedia.com")!
    static let email = "capturecampmedia@icloud.com"
    static let copyright = "© 2026 Capture Camp Media"

    /// "1.0 beta (4b7ed56)": the version people see, and the build it came
    /// from, as make-app.sh sets them.
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let shown = info?["CFBundleShortVersionString"] as? String else { return "development build" }
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == shown ? shown : "\(shown) (\(build))"
    }

    static func show(license: LicenseModel) {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        func line(_ text: String, _ extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
            NSAttributedString(string: text + "\n", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor,
                                                                  .paragraphStyle: centered].merging(extra) { $1 })
        }
        let credits = NSMutableAttributedString()
        credits.append(line(company, [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                                      .foregroundColor: NSColor.labelColor]))
        credits.append(line(website.host() ?? website.absoluteString, [.link: website]))
        credits.append(line(email, [.link: URL(string: "mailto:\(email)")!]))
        credits.append(line(""))
        credits.append(line(license.licensedTo ?? (license.status.problem ?? "Not licensed")))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: credits,
            .applicationVersion: version,
            // Already in the version line, so the box doesn't show it twice.
            .version: "",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
        ]
        if Bundle.main.infoDictionary?["CFBundleShortVersionString"] == nil {
            options[.applicationName] = "CCM Card Ingest"
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate()
    }
}
