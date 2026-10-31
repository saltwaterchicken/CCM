import AppKit
import CardIngestCore
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The setup tutorial: opens by itself the first time Card Ingest runs for
/// someone on this Mac, and from Help › Setup Tutorial… after that. Each step
/// sets something up for real, saved straight to the settings file like the
/// Job panel; Show Me points at the same setting in the main window.
struct TutorialView: View {
    @Bindable var settings: SettingsModel
    var watcher: CardWatcher
    @Environment(HelpModel.self) private var help
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = Step.welcome
    @State private var initials = ""
    @State private var topicCopied = false

    /// Seen once on this Mac (for this user), so it opens by itself only the first time.
    static let seenKey = "setupTutorialSeen"

    enum Step: Int, CaseIterable {
        case welcome, initials, destination, backup, counter, whenDone, phone, expect, done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if step != .welcome, step != .done {
                Text("Step \(step.rawValue) of \(Step.allCases.count - 2)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { page }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .onAppear {
            UserDefaults.standard.set(true, forKey: Self.seenKey)
            initials = Initials.current(in: settings.settings.folderName) ?? ""
            // Stays in front of the main window, so Show Me doesn't hide it.
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("tutorial") == true }?.level = .floating
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            title("Welcome to Card Ingest")
            para("Card Ingest copies your camera cards safely: every file is copied, read back and checked against the card "
                 + "before anything else happens. It renames each file as it lands, backs the card up to the server, and lets "
                 + "you start rating while the rest is still copying.")
            para("This takes about two minutes. Whatever you choose is saved straight away, and you can change any of it "
                 + "later in the Job panel. Help › Setup Tutorial… brings this back.")
        case .initials:
            title("Your initials")
            para("Your initials go in every card folder and every file name, so your cards and photos are never mixed up "
                 + "with anyone else's.")
            HStack {
                TextField("Initials", text: $initials)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.monospaced())
                    .frame(width: 140)
                    .onChange(of: initials) {
                        let cleaned = Initials.clean(initials)
                        if cleaned != initials { initials = cleaned }
                        if let changed = Initials.apply(cleaned, to: settings.settings) {
                            settings.change { $0 = changed }
                        }
                    }
                Text("Letters or numbers, up to 6").font(.caption).foregroundStyle(.secondary)
            }
            if Initials.current(in: settings.settings.folderName) == nil {
                Label("Your folder name has no initials before {iseq} to change. Edit Folder name in the Job panel instead.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            preview
            showMe(.folderName)
        case .destination:
            title("Where cards are copied")
            para("Each card gets its own folder here, named like the one below. Pick a fast drive: the copy runs at its speed, "
                 + "and the card can only go to its Trash once this copy is verified.")
            folderRow(settings.settings.destinationRoot) {
                if let url = JobPanel.chooseFolder("Choose where cards are copied to", startingAt: settings.settings.destinationRootURL) {
                    settings.change { $0.destinationRoot = JobPanel.displayPath(url) }
                }
            }
            if let problem = settings.settings.folderProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text("Copies go to: \(settings.destinationPreview)").foregroundStyle(.secondary).textSelection(.enabled)
            showMe(.destination)
        case .backup:
            title("The backup on the server")
            para("Choose the folder on the server (the Synology) where cards are backed up. Each file is sent there from the "
                 + "copy you just made, in the background, so a slow server never holds up the card.")
            para("The light in the Server panel turns green when the server is mounted, Wi-Fi is off and the network cable is "
                 + "in. Red only warns: if a card wasn't backed up, Sync With Server catches it up later.")
            folderRow(settings.settings.backupRootURL == nil ? "None yet" : settings.settings.backupRoot) {
                if let url = JobPanel.chooseFolder("Choose the backup folder on the server", startingAt: settings.settings.backupRootURL) {
                    settings.change { $0.backupRoot = JobPanel.displayPath(url) }
                }
            }
            para("No server here? Skip this; you can add it later under Backup in the Job panel.")
            showMe(.server)
        case .counter:
            title("The card counter")
            para("Every card gets the next number: 001, 002, 003… It's the {iseq} in the folder name, and it goes up by one only "
                 + "after a card copies and verifies, so a stopped copy never uses one up.")
            para("Starting fresh? Leave it at 1. Carrying on from earlier cards? Enter the number after your last one, so no two "
                 + "cards ever get the same name.")
            HStack {
                Text("Next card number")
                TextField("1", value: Binding(get: { settings.settings.nextImportNumber },
                                              set: { number in settings.change { $0.nextImportNumber = max(1, number) } }),
                          format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            preview
            showMe(.importNumber)
        case .whenDone:
            title("When a card is done")
            Toggle("Move the card's photos and videos to the card's Trash once every copy is verified", isOn: Binding(
                get: { settings.settings.trashAfterVerify }, set: { on in settings.change { $0.trashAfterVerify = on } }))
            para("Nothing is ever erased: the originals stay in the card's Trash until you format the card in the camera, which "
                 + "is when the space frees up. The first 3 cards ask first.")
                .padding(.leading, 20)
            Toggle("Eject the card when finished", isOn: Binding(
                get: { settings.settings.ejectWhenDone }, set: { on in settings.change { $0.ejectWhenDone = on } }))
            if settings.settings.rating.available {
                Toggle("Rate sharpness and exposure as each photo lands", isOn: Binding(
                    get: { settings.settings.rating.autoRating }, set: { on in settings.change { $0.rating.autoRating = on } }))
                para("Gives 1 star to keepers and 0 to soft or badly exposed photos (in blue, so you can tell them from yours), "
                     + "never touching a photo you've rated. Calibrate… in the Job panel tunes it to your eye.")
                    .padding(.leading, 20)
            }
            showMe(.whenDone)
        case .phone:
            phone
        case .expect:
            title("What happens with each card")
            numbered(1, "Put the card in. It shows at the top left with how many files it has.", target: .cards)
            numbered(2, "Press Copy (or ⌘↩). Each file is copied, read back and checked against the card.")
            numbered(3, "Photos appear in the grid as they land. Click one and press 0 to 5 to rate; Space looks closer, "
                     + "at 100% to check focus.", target: .starFilter)
            numbered(4, "Once every copy is verified, the originals go to the card's Trash and the card ejects. "
                     + "A receipt listing every file is saved in the card's folder.")
            numbered(5, "After culling and exporting from Lightroom, Sync With Server sends your stars and exports "
                     + "to the server. Nothing there is ever deleted or replaced.", target: .syncWithServer)
            numbered(6, "Stuck? Help › Card Ingest Help (⌘?) answers most questions, and Live Tech Support writes to us "
                     + "on WhatsApp.")
        case .done:
            title("You're set")
            para("Put a card in to start.")
            preview
            para("Help › Setup Tutorial… brings this back any time.")
        }
    }

    /// ntfy's page on the App Store, for the phone's camera.
    static let ntfyAppStore = "https://apps.apple.com/app/ntfy/id1625396347"

    /// Alerts on the phone: get ntfy, then this Mac's topic, copied to paste in.
    @ViewBuilder
    private var phone: some View {
        let topic = settings.settings.notifications.topic.trimmingCharacters(in: .whitespaces)
        title("Alerts on your phone")
        para("Card Ingest can tell your iPhone (and Watch) when a card is copied, when its backup is on the server, and when "
             + "Sync With Server is done, so you can walk away from the Mac. It uses ntfy, a free app.")
        HStack(alignment: .top, spacing: 16) {
            if let code = Self.qrCode(Self.ntfyAppStore) {
                Image(nsImage: code)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 120, height: 120)
            }
            VStack(alignment: .leading, spacing: 8) {
                numberedLine(1, "Get ntfy on your iPhone: point its camera at this code, or search the App Store for ntfy.")
                numberedLine(2, topic.isEmpty ? "Make your topic: the private name your alerts are sent under."
                                              : "Copy your topic below, then paste it on the phone.")
                numberedLine(3, "In ntfy, tap +, paste the topic, leave the server as ntfy.sh and tap Subscribe. "
                             + "Allow notifications when it asks.")
            }
        }
        if topic.isEmpty {
            Button("Make My Topic") {
                settings.change { $0.notifications.topic = NotificationSettings.newTopic() }
            }
            .controlSize(.large)
        } else {
            HStack {
                Text(topic).font(.title3.monospaced()).textSelection(.enabled)
                Spacer()
                Button(topicCopied ? "Copied" : "Copy Topic") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(topic, forType: .string)
                    topicCopied = true
                }
                .controlSize(.large)
            }
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            para("Not at the phone? Paste it into a message to yourself, then copy it from there on the phone. Keep it to "
                 + "yourself: anyone with the topic can read your alerts.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Send Test Notification") { watcher.sendTestNotification() }
                Text("Also in the Help menu.").font(.caption).foregroundStyle(.secondary)
            }
            para("Messages listed in ntfy but no alerts? Delete ntfy, install it again and subscribe again.")
                .font(.callout).foregroundStyle(.secondary)
        }
        para("No phone alerts wanted? Skip this with Next.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func numberedLine(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.headline).frame(width: 16)
            para(text)
        }
    }

    /// A QR code for `text`, sharp at any size.
    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private var buttons: some View {
        HStack {
            if step == .welcome {
                Button("Skip for Now") { close() }
            } else if step != .done {
                Button("Back") { move(-1) }
            }
            Spacer()
            switch step {
            case .welcome: Button("Start") { move(1) }.keyboardShortcut(.defaultAction)
            case .done: Button("Finish") { close() }.keyboardShortcut(.defaultAction)
            default: Button("Next") { move(1) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ by: Int) {
        step = Step(rawValue: step.rawValue + by) ?? step
        topicCopied = false
    }

    private func close() {
        step = .welcome
        dismissWindow(id: "tutorial")
    }

    /// The next card's folder and a file in it, as they'll be named.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch settings.folderPreview {
            case let .success(name): Text("Next card: \(name)").font(.body.monospaced())
            case let .failure(error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text("Files: \(settings.fileNamePreview)").font(.body.monospaced()).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title).bold()
    }

    private func para(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private func folderRow(_ path: String, choose: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "folder")
            Text(path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…", action: choose)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }

    private func numbered(_ number: Int, _ text: String, target: HelpTarget? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.headline).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                para(text)
                if let target { showMe(target) }
            }
        }
    }

    /// Points at the same thing in the main window, or says where it shows up.
    private func showMe(_ target: HelpTarget) -> some View {
        HStack {
            Button("Show Me") {
                if watcher.grid.isViewing { watcher.grid.closeView() }
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.orderFront(nil)
                help.show(target)
            }
            .controlSize(.small)
            if !help.onScreen.contains(target) {
                Text("Shows up later: \(target.place).").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
