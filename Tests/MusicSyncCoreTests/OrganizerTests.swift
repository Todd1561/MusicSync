import Foundation
import Testing
@testable import MusicSyncCore

private func row(_ rows: [OrganizeRow], _ name: String) -> OrganizeRow {
    rows.first { $0.fileName == name }!
}

@Test func existingFolderDecidesEitherOrder() {
    let rows = Organizer.analyze(
        fileNames: ["Coldplay - Yellow.mp3", "Clocks - coldplay.m4a"],
        existingBands: ["Coldplay", "Cake"])
    let a = row(rows, "Coldplay - Yellow.mp3"), b = row(rows, "Clocks - coldplay.m4a")
    #expect(a.band == "Coldplay" && a.song == "Yellow" && a.confident && a.include)
    #expect(b.band == "Coldplay" && b.song == "Clocks" && b.confident && b.ext == "m4a")
}

@Test func repetitionInBatchDecides() {
    let rows = Organizer.analyze(
        fileNames: ["Weezer - Buddy Holly.mp3", "Island In The Sun - Weezer.mp3", "Say It Ain't So - weezer.mp3"],
        existingBands: [])
    #expect(rows.allSatisfy { $0.confident })
    #expect(rows.map(\.band) == ["Weezer", "Weezer", "Weezer"])   // one spelling for the folder
    #expect(Set(rows.map(\.song)) == ["Buddy Holly", "Island In The Sun", "Say It Ain't So"])
}

@Test func tagsDecideWhenNothingElseDoes() {
    let rows = Organizer.analyze(
        fileNames: ["Hey Jude - The Beatles.mp3", "Lonely Song - Solo Act.mp3"],
        existingBands: [],
        tags: ["Hey Jude - The Beatles.mp3": TrackTags(artist: "Beatles", title: "Hey Jude")])
    let a = row(rows, "Hey Jude - The Beatles.mp3")
    #expect(a.band == "The Beatles" && a.song == "Hey Jude" && a.confident)
    let b = row(rows, "Lonely Song - Solo Act.mp3")
    #expect(!b.confident && !b.include)                 // pure guess: left unticked
    #expect(b.band == "Solo Act" && b.song == "Lonely Song")   // fallback is Song - Band
}

@Test func punctuationAndHyphensInBandNames() {
    let rows = Organizer.analyze(
        fileNames: ["AC-DC - Back In Black.mp3", "Thunderstruck - AC/DC.mp3", "Burnin' for You - Blue Oyster Cult.mp3",
                    "01 - Cake - The Distance.mp3", "Short Skirt-Cake.mp3"],
        existingBands: ["AC_DC", "Blue Öyster Cult", "Cake"])
    #expect(row(rows, "AC-DC - Back In Black.mp3").band == "AC_DC")
    #expect(row(rows, "AC-DC - Back In Black.mp3").song == "Back In Black")
    #expect(row(rows, "Thunderstruck - AC/DC.mp3").band == "AC_DC")
    #expect(row(rows, "Burnin' for You - Blue Oyster Cult.mp3").band == "Blue Öyster Cult")
    #expect(row(rows, "01 - Cake - The Distance.mp3").song == "The Distance")
    #expect(row(rows, "Short Skirt-Cake.mp3").band == "Cake")
    #expect(rows.allSatisfy { $0.confident })
}

@Test func noHyphenIsLeftForTheUser() {
    let rows = Organizer.analyze(fileNames: ["Mystery Track.mp3"], existingBands: ["Cake"])
    #expect(rows[0].band.isEmpty && rows[0].song == "Mystery Track" && !rows[0].include)
}

@Test func moveCreatesBandFolderAndNeverOverwrites() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("organize-test-\(UUID().uuidString)")
    let src = root.appendingPathComponent("in"), dst = root.appendingPathComponent("out")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try fm.createDirectory(at: dst.appendingPathComponent("AC_DC"), withIntermediateDirectories: true)
    for name in ["Thunderstruck - AC/DC".replacingOccurrences(of: "/", with: ":") + ".mp3",
                 "What: A Song - New Band.mp3", "Yellow - Coldplay.mp3", "notes.txt", "Other - Format.m4a"] {
        try Data(name.utf8).write(to: src.appendingPathComponent(name))
    }
    try fm.createDirectory(at: dst.appendingPathComponent("Coldplay"), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: dst.appendingPathComponent("Coldplay/Yellow.mp3"))

    let names = try Organizer.listAudioFiles(in: src)
    #expect(names.count == 3)                                   // notes.txt and the .m4a ignored
    let bands = Organizer.listFolders(in: dst)
    var rows = Organizer.analyze(fileNames: names, existingBands: bands)
    for i in rows.indices where rows[i].band.isEmpty == false { rows[i].include = true }
    var outcomes: [String: MoveOutcome] = [:]
    for r in rows { outcomes[r.fileName] = Organizer.move(row: r, source: src, dest: dst, existingBands: bands) }

    #expect(outcomes["Yellow - Coldplay.mp3"] == .exists)
    #expect(String(decoding: try Data(contentsOf: dst.appendingPathComponent("Coldplay/Yellow.mp3")), as: UTF8.self) == "old")
    #expect(fm.fileExists(atPath: src.appendingPathComponent("Yellow - Coldplay.mp3").path))
    #expect(fm.fileExists(atPath: dst.appendingPathComponent("AC_DC/Thunderstruck.mp3").path))
    #expect(fm.fileExists(atPath: dst.appendingPathComponent("New Band/What_ A Song.mp3").path))
    #expect(try fm.contentsOfDirectory(atPath: src.path).sorted() == ["Other - Format.m4a", "Yellow - Coldplay.mp3", "notes.txt"])
}

@Test func matchKeys() {
    #expect(Organizer.matchKey("AC/DC") == Organizer.matchKey("ac_dc"))
    #expect(Organizer.matchKey("The Beatles") == Organizer.matchKey("beatles"))
    #expect(Organizer.matchKey("Simon & Garfunkel") == Organizer.matchKey("Simon and Garfunkel"))
    #expect(Organizer.matchKey("The") == "the")
    #expect(Organizer.sanitize(" What: A/Song. ") == "What_ A_Song")
}
