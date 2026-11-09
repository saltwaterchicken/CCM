import AVFoundation
import XCTest
@testable import MediaSherpaCore

/// Stars and keywords inside clips, and Save to Clips: real clips, made here, must
/// keep their picture and still play, and clips wait for the save before going up.
final class ClipMetadataTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ClipMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    /// A few real frames, with the index at the end, or at the front with no spare room.
    private func makeClip(_ name: String, type: AVFileType, indexFirst: Bool = false) async throws -> URL {
        let url = base.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        writer.shouldOptimizeForNetworkUse = indexFirst
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func assertPlays(_ url: URL, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, line: line)
        let tracks = try await asset.load(.tracks)
        XCTAssertEqual(tracks.count, 1, line: line)
        _ = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(value: 5, timescale: 30))
    }

    private func checkEmbedding(_ url: URL, line: UInt = #line) async throws {
        let media = try ClipMetadata.mediaDigest(of: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        try ClipMetadata.embed(stars: 3, keywords: ["Camp", "Lake"], into: url)
        let inside = ClipMetadata.read(from: url)
        XCTAssertEqual(inside.stars, 3, line: line)
        XCTAssertEqual(inside.keywords, ["Camp", "Lake"], line: line)
        XCTAssertEqual(try ClipMetadata.mediaDigest(of: url), media, "Picture and sound untouched", line: line)
        XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, date, line: line)
        try await assertPlays(url, line: line)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".saving") }, [], line: line)
    }

    func testAnMP4KeepsItsPictureAndPlays() async throws {
        try await checkEmbedding(makeClip("a.mp4", type: .mp4))
    }

    func testAQuickTimeClipKeepsItsPictureAndPlays() async throws {
        try await checkEmbedding(makeClip("a.mov", type: .mov))
    }

    func testAQuickTimeIndexWithNoRoomMovesToTheEnd() async throws {
        try await checkEmbedding(makeClip("first.mov", type: .mov, indexFirst: true))
    }

    func testSavingAgainReplacesTheBlockAndKeywordsCanComeOff() async throws {
        for (name, type) in [("again.mp4", AVFileType.mp4), ("again.mov", AVFileType.mov)] {
            let url = try await makeClip(name, type: type)
            try ClipMetadata.embed(stars: 3, keywords: ["Camp", "Lake"], into: url)
            try ClipMetadata.embed(stars: 5, keywords: ["Camp"], replacingKeywords: true, into: url)
            let inside = ClipMetadata.read(from: url)
            XCTAssertEqual(inside.stars, 5)
            XCTAssertEqual(inside.keywords, ["Camp"])
            let bytes = try Data(contentsOf: url)
            XCTAssertNotNil(bytes.range(of: Data("<?xpacket begin".utf8)))
            let first = try XCTUnwrap(bytes.range(of: Data("<?xpacket begin".utf8)))
            XCTAssertNil(bytes[first.upperBound...].range(of: Data("<?xpacket begin".utf8)), "No second block")
            try await assertPlays(url)
        }
    }

    func testKeywordsAddToThoseAlreadyInside() async throws {
        let url = try await makeClip("add.mov", type: .mov)
        try ClipMetadata.embed(stars: nil, keywords: ["From Premiere"], into: url)
        try ClipMetadata.embed(stars: 2, keywords: ["Camp"], into: url)
        XCTAssertEqual(ClipMetadata.read(from: url).keywords, ["From Premiere", "Camp"])
    }

    func testAClipCutShortIsLeftAlone() async throws {
        let url = try await makeClip("cut.mp4", type: .mp4)
        var data = try Data(contentsOf: url)
        data.removeLast(100)
        try data.write(to: url)
        XCTAssertThrowsError(try ClipMetadata.embed(stars: 3, keywords: ["Camp"], into: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testOnlyMP4AndQuickTimeCanHoldIt() {
        XCTAssertTrue(ClipMetadata.canEmbed("A.MP4"))
        XCTAssertTrue(ClipMetadata.canEmbed("A.mov"))
        XCTAssertFalse(ClipMetadata.canEmbed("A.MXF"))
        XCTAssertFalse(ClipMetadata.canEmbed("A.MTS"))
    }

    /// One-off, on real camera clips: CLIP_SAMPLES holds them, CLIP_SAMPLES_OUT gets tagged copies.
    func testRealClips() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let samples = env["CLIP_SAMPLES"], let out = env["CLIP_SAMPLES_OUT"] else { throw XCTSkip("No samples named") }
        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: samples) where ClipMetadata.canEmbed(name) {
            let source = URL(fileURLWithPath: samples).appendingPathComponent(name)
            let target = URL(fileURLWithPath: out).appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
            let media = try ClipMetadata.mediaDigest(of: source)
            try ClipMetadata.embed(stars: 3, keywords: ["apptest", "apptest2026"], into: target)
            XCTAssertEqual(try ClipMetadata.mediaDigest(of: target), media, name)
            let inside = ClipMetadata.read(from: target)
            XCTAssertEqual(inside.stars, 3, name)
            XCTAssertEqual(inside.keywords, ["apptest", "apptest2026"], name)
            let asset = AVURLAsset(url: target), original = AVURLAsset(url: source)
            let tracks = try await asset.load(.tracks), originalTracks = try await original.load(.tracks)
            XCTAssertEqual(tracks.count, originalTracks.count, name)
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable, name)
            let length = try await asset.load(.duration)
            _ = try await AVAssetImageGenerator(asset: asset).image(at: CMTimeMultiplyByRatio(length, multiplier: 1, divisor: 2))
            let sizes = try [source, target].map { try fm.attributesOfItem(atPath: $0.path)[.size] as? Int64 ?? 0 }
            print("REAL \(name): \(sizes[0]) -> \(sizes[1]), video identical, plays, stars and keywords read back")
        }
    }

    // MARK: Save to Clips

    private func folder(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func shot(_ url: URL) -> Shot {
        ShotList(fileTypes: FileTypes(), files: [
            CopiedFile(newName: url.lastPathComponent, originalPath: "DCIM/" + url.lastPathComponent, size: 1, originalModified: nil,
                       checksum: "", destinations: [url], alreadyThere: true),
        ]).shots[0]
    }

    /// A finished card with one rated, keyworded clip and one clip left alone.
    private func card() async throws -> (folder: URL, tagged: Shot, plain: Shot, plainBytes: Data) {
        let card = try folder("CARD-001")
        try "receipt".write(to: card.appendingPathComponent("Receipt_CARD_2026.csv"), atomically: true, encoding: .utf8)
        try SavedClips.startHolding(in: card)
        let tagged = try await makeClip("t.mov", type: .mov), plain = try await makeClip("p.mp4", type: .mp4)
        let taggedAt = card.appendingPathComponent("A_0001.MOV"), plainAt = card.appendingPathComponent("A_0002.MP4")
        try fm.moveItem(at: tagged, to: taggedAt)
        try fm.moveItem(at: plain, to: plainAt)
        let shots = (shot(taggedAt), shot(plainAt))
        try Stars.set(4, on: shots.0)
        try Keywords.add(["Camp"], to: shots.0)
        return (card, shots.0, shots.1, try Data(contentsOf: plainAt))
    }

    func testSaveWritesIntoClipsThenSendsThem() async throws {
        let (card, tagged, plain, plainBytes) = try await card()
        let root = try folder("Server")
        XCTAssertEqual(SavedClips.waiting(in: card, fileTypes: FileTypes()), ["A_0001.MOV", "A_0002.MP4"])

        let outcome = ClipSaver.save([tagged, plain], in: card, root: root, isThere: { _ in true })
        XCTAssertEqual(outcome.problems, [])
        XCTAssertEqual(outcome.saved, 2)
        XCTAssertEqual(outcome.sent, 2)
        let server = root.appendingPathComponent("CARD-001", isDirectory: true)
        let there = server.appendingPathComponent("A_0001.MOV")
        XCTAssertEqual(ClipMetadata.read(from: there).stars, 4, "What goes up has them inside")
        XCTAssertEqual(ClipMetadata.read(from: there).keywords, ["Camp"])
        XCTAssertTrue(fm.fileExists(atPath: server.appendingPathComponent("A_0001.xmp").path))
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("A_0002.MP4")), plainBytes, "Nothing to add: untouched")
        XCTAssertEqual(try Data(contentsOf: server.appendingPathComponent("A_0002.MP4")), plainBytes)
        XCTAssertEqual(SavedClips.waiting(in: card, fileTypes: FileTypes()), [])
        let row = try XCTUnwrap(SavedClips.load(from: card)?.row("A_0001.MOV"))
        let digest = try CardCopier.hashFile(there, name: "", progress: { _ in })
        XCTAssertEqual(row.checksum, XXHash64.hex(digest))
    }

    func testSaveWithTheServerAwayLeavesThemForSync() async throws {
        let (card, tagged, plain, _) = try await card()
        let root = try folder("Server")
        let outcome = ClipSaver.save([tagged, plain], in: card, root: root, isThere: { _ in false })
        XCTAssertEqual(outcome.saved, 2)
        XCTAssertEqual(outcome.waitingForServer, 2)
        let plan = try ServerSync.plan(local: card, server: root.appendingPathComponent("CARD-001"))
        XCTAssertEqual(plan.heldClips, 0)
        XCTAssertTrue(plan.adds.map(\.path).contains("A_0001.MOV"), "Saved, so Sync sends it")
    }

    func testAClipAlreadyOnTheServerIsReportedNotReplaced() async throws {
        let (card, tagged, _, _) = try await card()
        let root = try folder("Server")
        let server = try folder("Server/CARD-001")
        let old = server.appendingPathComponent("A_0001.MOV")
        try fm.copyItem(at: card.appendingPathComponent("A_0001.MOV"), to: old)
        let before = try Data(contentsOf: old)
        let outcome = ClipSaver.save([tagged], in: card, root: root, isThere: { _ in true })
        XCTAssertEqual(outcome.sent, 0)
        XCTAssertTrue(outcome.problems.first?.contains("can't be changed") == true)
        XCTAssertEqual(try Data(contentsOf: old), before)
    }

    func testAnUnfinishedCopyIsntSaved() async throws {
        let (card, tagged, _, _) = try await card()
        try fm.removeItem(at: card.appendingPathComponent("Receipt_CARD_2026.csv"))
        let bytes = try Data(contentsOf: card.appendingPathComponent("A_0001.MOV"))
        let outcome = ClipSaver.save([tagged], in: card, root: nil)
        XCTAssertEqual(outcome.saved, 0)
        XCTAssertEqual(outcome.problems.count, 1)
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("A_0001.MOV")), bytes)
    }

    func testSyncHoldsBackWaitingClipsAndTheirSidecars() async throws {
        let (card, _, _, _) = try await card()
        let plan = try ServerSync.plan(local: card, server: base.appendingPathComponent("Server/CARD-001"))
        XCTAssertEqual(plan.heldClips, 2)
        let adds = plan.adds.map(\.path)
        XCTAssertFalse(adds.contains("A_0001.MOV"))
        XCTAssertFalse(adds.contains("A_0001.xmp"))
        XCTAssertFalse(adds.contains(SavedClips.fileName))
    }

    func testACardFromBeforeHoldsNothingBack() async throws {
        let (card, _, _, _) = try await card()
        try fm.removeItem(at: card.appendingPathComponent(SavedClips.fileName))
        XCTAssertEqual(SavedClips.waiting(in: card, fileTypes: FileTypes()), [])
        XCTAssertEqual(SavedClips.waitingCards(in: base, fileTypes: FileTypes()), [])
        let plan = try ServerSync.plan(local: card, server: base.appendingPathComponent("Server/CARD-001"))
        XCTAssertEqual(plan.heldClips, 0)
        XCTAssertTrue(plan.adds.map(\.path).contains("A_0001.MOV"))
    }

    func testWaitingCardsAreListed() async throws {
        let (card, _, _, _) = try await card()
        let waiting = SavedClips.waitingCards(in: base, fileTypes: FileTypes())
        XCTAssertEqual(waiting.map(\.folder.lastPathComponent), [card.lastPathComponent])
        XCTAssertEqual(waiting.first?.clips, 2)
    }

    // MARK: Clearing the card

    /// A clip copied earlier, grown by Save to Clips, with a photo beside it.
    private func clearingFixture() throws -> (check: CardCheck, clip: CardFile, photo: CardFile, card: URL) {
        let card = try folder("Copied-001")
        try Data(count: 1500).write(to: card.appendingPathComponent("A_0001.MP4"))
        try Data(count: 500).write(to: card.appendingPathComponent("A_0002.CR3"))
        let clip = CardFile(relativePath: "DCIM/C0001.MP4", size: 1000), photo = CardFile(relativePath: "DCIM/P0002.CR3", size: 500)
        let check = CardCheck(newFiles: [], alreadyImported: [
            ImportedFile(file: clip, folder: card, newName: "A_0001.MP4"),
            ImportedFile(file: photo, folder: card, newName: "A_0002.CR3"),
        ])
        return (check, clip, photo, card)
    }

    func testASavedClipThatGrewStillCountsAsASafeCopy() throws {
        let (check, clip, photo, card) = try clearingFixture()
        XCTAssertEqual(CardClearer.safelyCopied(report: nil, check: check), [photo], "A changed size with no record isn't safe")
        try SavedClips.record(.init(name: "A_0001.MP4", size: 1500, checksum: "0", savedAt: "x"), in: card)
        XCTAssertEqual(CardClearer.safelyCopied(report: nil, check: check), [clip, photo])
        try Data(count: 1400).write(to: card.appendingPathComponent("A_0001.MP4"))
        XCTAssertEqual(CardClearer.safelyCopied(report: nil, check: check), [photo], "Not the size it was saved at")
    }

    func testTheCautiousSettingKeepsClipsUntilTheyreOnTheServer() throws {
        let (check, clip, photo, card) = try clearingFixture()
        let files = [clip, photo], types = FileTypes()
        let root = try folder("Server")
        func clearing(_ root: URL?) -> [CardFile] {
            CardClearer.withoutClipsNotOnServer(files, report: nil, check: check, fileTypes: types, root: root)
        }
        XCTAssertEqual(clearing(nil), [photo], "No server: clips stay")
        XCTAssertEqual(clearing(root), [photo], "Not there yet")
        let there = try folder("Server/\(card.lastPathComponent)").appendingPathComponent("A_0001.MP4")
        try Data(count: 1000).write(to: there)
        XCTAssertEqual(clearing(root), [photo], "An untagged copy, a different size, isn't this one")
        try fm.removeItem(at: there)
        try Data(count: 1500).write(to: there)
        XCTAssertEqual(clearing(root), [clip, photo])
    }

    func testAnInterruptedCopyStillRecognisesItsFolder() throws {
        let card = try folder("Stopped-001")
        try SavedClips.startHolding(in: card)
        try Data(count: 10).write(to: card.appendingPathComponent("A_0001.MP4"))
        let planned = [PlannedFile(source: CardFile(relativePath: "DCIM/C.MP4", size: 10), newName: "A_0001.MP4")]
        XCTAssertTrue(ImportPlanner.holdsNothingElse(card, planned))
    }

    func testRecordingKeepsWhenTheWaitBegan() throws {
        let card = try folder("Waited")
        try SavedClips.startHolding(in: card)
        let file = card.appendingPathComponent(SavedClips.fileName)
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.creationDate: then], ofItemAtPath: file.path)
        try SavedClips.record(.init(name: "A.MOV", size: 1, checksum: "0", savedAt: "x"), in: card)
        XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.creationDate] as? Date, then)
    }

    func testTheSettingIsOffUnlessAsked() throws {
        XCTAssertFalse(IngestSettings().keepClipsOnCardUntilOnServer)
        let xml = "<plist version=\"1.0\"><dict><key>keepClipsOnCardUntilOnServer</key><true/></dict></plist>"
        let settings = try PropertyListDecoder().decode(IngestSettings.self, from: Data(xml.utf8))
        XCTAssertTrue(settings.keepClipsOnCardUntilOnServer)
    }

    func testHelpFindsSaveToClips() {
        XCTAssertEqual(Help.search("premiere").first?.id, "save-to-clips")
    }
}
