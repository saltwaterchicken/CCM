import XCTest
@testable import CardIngestCore

/// The grid's selection and keys, and shots arriving as a Copy runs.
final class CullingTests: XCTestCase {
    private func shot(_ name: String) -> Shot {
        ShotList(fileTypes: FileTypes(), files: [
            CopiedFile(newName: name, originalPath: "DCIM/" + name, size: 1, originalModified: nil, checksum: "0",
                       destinations: [URL(fileURLWithPath: "/Main/" + name)], alreadyThere: false),
        ]).shots[0]
    }

    /// Photos 1 to 3, a clip, then photo 5, each with 1 star.
    private func grid() -> CullGrid {
        var grid = CullGrid()
        let names = ["ES_0001.CR3", "ES_0002.CR3", "ES_0003.CR3", "ES_0004.MP4", "ES_0005.CR3"]
        for (i, name) in names.enumerated() {
            let one = shot(name)
            grid.add(LandedShot(shot: one, stars: one.isRatable ? 1 : nil, position: i))
        }
        return grid
    }

    private let p1 = "es_0001", p2 = "es_0002", p3 = "es_0003", clip = "es_0004", p5 = "es_0005"

    func testShotsKeepTheOrderTheyLanded() {
        var grid = CullGrid()
        grid.add(LandedShot(shot: shot("ES_0002.CR3"), stars: 1, position: 1))
        grid.add(LandedShot(shot: shot("ES_0001.CR3"), stars: 3, position: 0))
        grid.add(LandedShot(shot: shot("ES_0003.CR3"), stars: 1, position: 2))
        XCTAssertEqual(grid.shots.map(\.id), [p1, p2, p3])
        XCTAssertEqual(grid.stars[p1], 3, "A rating set in the camera shows")
        XCTAssertTrue(grid.selected.isEmpty)
    }

    func testClickShiftClickAndCommandClick() {
        var grid = grid()
        grid.click(p2)
        XCTAssertEqual(grid.selected, [p2])
        grid.click(p5, shift: true)
        XCTAssertEqual(grid.selected, [p2, p3, clip, p5])
        grid.click(p1, shift: true)
        XCTAssertEqual(grid.selected, [p1, p2], "Shift ranges from the last plain click")
        grid.click(p5, command: true)
        XCTAssertEqual(grid.selected, [p1, p2, p5])
        grid.click(p1, command: true)
        XCTAssertEqual(grid.selected, [p2, p5])
        grid.click(p3)
        XCTAssertEqual(grid.selected, [p3])
        XCTAssertEqual(grid.focus, p3)
    }

    func testArrowsMoveOneAtATimeAndStopAtTheEnds() {
        var grid = grid()
        grid.move(by: 1)
        XCTAssertEqual(grid.selected, [p1], "Nothing selected: start at the first")
        grid.move(by: -1)
        XCTAssertEqual(grid.selected, [p1])
        grid.move(by: 1)
        grid.move(by: 1)
        grid.move(by: 1)
        XCTAssertEqual(grid.selected, [clip], "Arrows stop on videos too")
        grid.move(by: 1)
        grid.move(by: 1)
        XCTAssertEqual(grid.selected, [p5])

        var empty = CullGrid()
        empty.move(by: 1)
        XCTAssertNil(empty.focus)
    }

    func testANumberRatesAndMovesOnToTheNextPhoto() {
        var grid = grid()
        grid.click(p2)
        XCTAssertEqual(grid.rate(4).map(\.id), [p2])
        XCTAssertEqual(grid.stars[p2], 4)
        XCTAssertEqual(grid.selected, [p3])
        grid.rate(0)
        XCTAssertEqual(grid.stars[p3], 0)
        XCTAssertEqual(grid.selected, [p5], "Skips the clip")
        grid.rate(2)
        XCTAssertEqual(grid.stars[p5], 2)
        XCTAssertEqual(grid.selected, [p5], "The last photo stays selected")
    }

    func testRatingASelectionRatesThemAllAndStaysPut() {
        var grid = grid()
        grid.click(p1)
        grid.click(clip, shift: true)
        let written = grid.rate(5)
        XCTAssertEqual(written.map(\.id), [p1, p2, p3], "Videos get no star")
        XCTAssertEqual([p1, p2, p3].map { grid.stars[$0] }, [5, 5, 5])
        XCTAssertNil(grid.stars[clip])
        XCTAssertEqual(grid.selected, [p1, p2, p3, clip])
    }

    func testRatingAClipAloneDoesNothing() {
        var grid = grid()
        grid.click(clip)
        XCTAssertEqual(grid.rate(3), [])
        XCTAssertNil(grid.stars[clip])
        XCTAssertEqual(grid.selected, [p5], "Moves on to the next photo")
    }

    func testStarsStayInRangeAndSelectAll() {
        var grid = grid()
        grid.selectAll()
        XCTAssertEqual(grid.selected.count, 5)
        grid.rate(9)
        XCTAssertEqual(grid.stars[p1], 5)
    }

    // MARK: Filter

    /// Photo 1 at 1 star, 2 at 3 stars, 3 flagged at 0, a clip, 5 at 1 star.
    private func ratedGrid() -> CullGrid {
        var grid = grid()
        grid.click(p2)
        grid.rate(3)
        grid.click(p3)
        grid.rate(0)
        grid.click(p1)
        return grid
    }

    func testFilterShowsByStarsAndHidesClipsUnlessAll() {
        var grid = ratedGrid()
        XCTAssertEqual(grid.visible.map(\.id), [p1, p2, p3, clip, p5])
        grid.filter = .atLeast(1)
        XCTAssertEqual(grid.visible.map(\.id), [p1, p2, p5])
        grid.filter = .atLeast(3)
        XCTAssertEqual(grid.visible.map(\.id), [p2])
        grid.filter = .flagged
        XCTAssertEqual(grid.visible.map(\.id), [p3])
        XCTAssertEqual(StarFilter.choices.map(\.label), ["All", "★1+", "★2+", "★3+", "★4+", "★5", "0★"])
    }

    func testUnratedPhotosOnlyShowWithAll() {
        var grid = ratedGrid()
        grid.add(LandedShot(shot: shot("ES_0006.JPG"), stars: nil, position: 5))
        grid.filter = .flagged
        XCTAssertEqual(grid.visible.map(\.id), [p3], "Not rated isn't flagged")
        grid.filter = .atLeast(1)
        XCTAssertEqual(grid.visible.map(\.id), [p1, p2, p5])
        grid.filter = .all
        XCTAssertEqual(grid.visible.map(\.id), [p1, p2, p3, clip, p5, "es_0006"])
    }

    func testFilteringDropsHiddenShotsFromTheSelection() {
        var grid = ratedGrid()
        grid.selectAll()
        grid.filter = .atLeast(1)
        XCTAssertEqual(grid.selected, [p1, p2, p5])
        XCTAssertEqual(grid.focus, p1)
        grid.filter = .atLeast(3)
        XCTAssertEqual(grid.selected, [p2])
        XCTAssertEqual(grid.focus, p2)
    }

    func testKeysOnlyReachWhatTheFilterShows() {
        var grid = ratedGrid()
        grid.filter = .atLeast(1)
        grid.click(p1)
        grid.move(by: 1)
        XCTAssertEqual(grid.selected, [p2], "Skips the hidden 0-star photo")
        grid.move(by: 1)
        XCTAssertEqual(grid.selected, [p5], "and the hidden clip")
        grid.click(p1)
        grid.click(p5, shift: true)
        XCTAssertEqual(grid.selected, [p1, p2, p5])
        grid.selectAll()
        XCTAssertEqual(grid.selected, [p1, p2, p5])
    }

    func testRatingAPhotoOutOfTheFilterMovesOnToTheNextShown() {
        var grid = ratedGrid()
        grid.filter = .atLeast(1)
        grid.click(p2)
        grid.rate(0)
        XCTAssertEqual(grid.visible.map(\.id), [p1, p5], "Flagged, so it's hidden")
        XCTAssertEqual(grid.selected, [p5])
        grid.rate(0)
        XCTAssertEqual(grid.visible.map(\.id), [p1])
        XCTAssertEqual(grid.selected, [p1], "At the end, the one before it")
        grid.rate(0)
        XCTAssertEqual(grid.visible, [])
        XCTAssertEqual(grid.selected, [])
        XCTAssertNil(grid.focus)
    }

    func testOpenSendsTheSelectionOrEverythingShown() {
        var grid = ratedGrid()
        grid.filter = .atLeast(1)
        grid.click(p5, command: true)
        XCTAssertEqual(grid.toOpen.map(\.lastPathComponent), ["ES_0001.CR3", "ES_0005.CR3"])
        grid.click(p1, command: true)
        grid.click(p5, command: true)
        XCTAssertEqual(grid.selected, [])
        XCTAssertEqual(grid.toOpen.map(\.lastPathComponent), ["ES_0001.CR3", "ES_0002.CR3", "ES_0005.CR3"],
                       "Nothing selected: everything the filter shows")
        grid.filter = .all
        XCTAssertEqual(grid.toOpen.count, 5)
    }

    func testOpenWithDefaultsToLightroomClassicAndLoadsFromTheFile() throws {
        XCTAssertEqual(IngestSettings().openWith, "Adobe Lightroom Classic")
        let data = try PropertyListEncoder().encode(["openWith": "com.adobe.bridge14"])
        XCTAssertEqual(try PropertyListDecoder().decode(IngestSettings.self, from: data).openWith, "com.adobe.bridge14")
        let old = try PropertyListEncoder().encode(["destinationRoot": "~/Pictures"])
        XCTAssertEqual(try PropertyListDecoder().decode(IngestSettings.self, from: old).openWith, "Adobe Lightroom Classic")
    }

    /// Shots reach the grid only once all their files are in, with stars already written.
    func testLiveShotsHandOverEachShotWhenItsLastFileLands() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("CullingTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let names = ["2026-10-14-ES_0001.CR3", "2026-10-14-ES_0001.JPG", "2026-10-14-ES_0002.JPG"]
        let planned = names.map { PlannedFile(source: CardFile(relativePath: "DCIM/" + $0, size: 1), newName: $0) }
        let live = LiveShots(planned: planned, fileTypes: FileTypes())
        var landed: [LandedShot] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            let file = CopiedFile(newName: name, originalPath: "DCIM/" + name, size: 1, originalModified: nil,
                                  checksum: "0", destinations: [url], alreadyThere: false)
            if let done = live.complete(file) { landed.append(done) }
            if name == names[0] { XCTAssertTrue(landed.isEmpty, "Waits for the pair's JPEG") }
        }
        XCTAssertEqual(landed.map(\.shot.files.count), [2, 1])
        XCTAssertEqual(landed.map(\.position), [0, 1])
        XCTAssertEqual(landed.map(\.stars), [1, nil], "A JPEG with no RAW gets no star")
        XCTAssertEqual(landed[0].shot.badge, "RAW+JPG")
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("2026-10-14-ES_0001.xmp").path))
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("2026-10-14-ES_0002.xmp").path))
    }
}
