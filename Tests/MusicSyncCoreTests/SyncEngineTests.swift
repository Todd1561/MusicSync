import Foundation
import Testing
@testable import MusicSyncCore

struct Sandbox {
    let root: URL
    var src: URL { root.appendingPathComponent("src") }
    var dst: URL { root.appendingPathComponent("dst") }
    let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musicsync-test-\(UUID().uuidString)")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    }

    func cleanup() { try? fm.removeItem(at: root) }

    func write(_ base: URL, _ rel: String, _ text: String, mtime: Date? = nil) throws {
        let url = base.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let mtime { try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
    }

    func read(_ base: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: base.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ base: URL, _ rel: String) -> Bool {
        fm.fileExists(atPath: base.appendingPathComponent(rel).path)
    }

    /// Every file under `base` with its contents, for before/after comparison.
    func snapshot(_ base: URL) -> [String: String] {
        var out: [String: String] = [:]
        let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let rel = String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
            out[rel] = read(base, rel)
        }
        return out
    }

    @discardableResult
    func sync(excludes: String = "") throws -> (plan: SyncPlan, result: SyncResult) {
        let rules = ExcludeRules(excludes)
        let s = try SyncEngine.scan(root: src, rules: rules, isDestination: false)
        let d = try SyncEngine.scan(root: dst, rules: rules, isDestination: true)
        let plan = SyncEngine.makePlan(source: s, dest: d)
        return (plan, SyncEngine.execute(plan: plan, source: src, dest: dst))
    }
}

@Test func freshCopyThenNothingToDo() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    try box.write(box.src, "A/one.mp3", "one")
    try box.write(box.src, "A/B/two.mp3", "two")
    try box.write(box.src, "top.txt", "top")
    try box.fm.createDirectory(at: box.src.appendingPathComponent("Empty"), withIntermediateDirectories: true)
    let before = box.snapshot(box.src)

    let first = try box.sync()
    #expect(first.result.copiedFiles == 3)
    #expect(first.result.errors.isEmpty)
    #expect(box.snapshot(box.dst) == before)
    #expect(box.exists(box.dst, "Empty"))

    let second = try box.sync()
    #expect(second.plan.isEmpty)
    #expect(second.plan.unchanged == 3)
    #expect(box.snapshot(box.src) == before)
}

@Test func changedFilesAreRecopied() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    try box.write(box.src, "same.txt", "same", mtime: old)
    try box.write(box.src, "size.txt", "v1", mtime: old)
    try box.write(box.src, "time.txt", "aaaa", mtime: old)
    try box.sync()

    try box.write(box.src, "same.txt", "same", mtime: old.addingTimeInterval(1))   // within tolerance
    try box.write(box.src, "size.txt", "version2", mtime: old)                     // size differs
    try box.write(box.src, "time.txt", "bbbb", mtime: old.addingTimeInterval(60))  // time differs
    let run = try box.sync()
    #expect(run.plan.copies.map(\.srcRel).sorted() == ["size.txt", "time.txt"])
    #expect(run.plan.deletes.isEmpty)
    #expect(box.read(box.dst, "size.txt") == "version2")
    #expect(box.read(box.dst, "time.txt") == "bbbb")
    #expect(try box.sync().plan.isEmpty)
}

@Test func oneHourDaylightSavingShiftIsNotAChange() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    try box.write(box.src, "dst-shift.mp3", "same", mtime: t)
    try box.write(box.dst, "dst-shift.mp3", "same", mtime: t.addingTimeInterval(3600))
    try box.write(box.src, "half-hour.mp3", "same", mtime: t)
    try box.write(box.dst, "half-hour.mp3", "same", mtime: t.addingTimeInterval(1800))
    try box.write(box.src, "resized.mp3", "longer", mtime: t)
    try box.write(box.dst, "resized.mp3", "same", mtime: t.addingTimeInterval(-3600))
    let run = try box.sync()
    #expect(run.plan.copies.map(\.srcRel).sorted() == ["half-hour.mp3", "resized.mp3"])
    #expect(run.plan.unchanged == 1)
}

@Test func extrasOnDestinationAreDeleted() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    try box.write(box.src, "keep/a.txt", "a")
    try box.sync()
    try box.write(box.dst, "stray.txt", "x")
    try box.write(box.dst, "OldAlbum/t1.mp3", "x")
    try box.write(box.dst, "OldAlbum/sub/t2.mp3", "x")
    try box.write(box.dst, "OldAlbum/.DS_Store", "x")
    try box.write(box.dst, "keep/extra.txt", "x")
    let before = box.snapshot(box.src)

    let run = try box.sync()
    #expect(run.plan.deleteDisplay == ["keep/extra.txt", "OldAlbum/", "stray.txt"])
    #expect(run.result.errors.isEmpty)
    #expect(!box.exists(box.dst, "stray.txt"))
    #expect(!box.exists(box.dst, "OldAlbum"))
    #expect(!box.exists(box.dst, "keep/extra.txt"))
    #expect(box.read(box.dst, "keep/a.txt") == "a")
    #expect(box.snapshot(box.src) == before)
}

@Test func excludedFoldersAreIgnoredOnBothSides() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    try box.write(box.src, "Music/a.mp3", "a")
    try box.write(box.src, "Podcasts/p.mp3", "p")
    try box.write(box.src, "Music/podcasts/q.mp3", "q")
    try box.write(box.src, "Rock/Live/l.mp3", "l")
    try box.write(box.src, "Rock/Studio/s.mp3", "s")
    try box.write(box.dst, "Podcasts/already.mp3", "x")
    try box.write(box.dst, "Gone/Podcasts/kept.mp3", "x")
    try box.write(box.dst, "Gone/other.mp3", "x")

    let run = try box.sync(excludes: " Podcasts , rock/live,, ")
    #expect(run.result.errors.isEmpty)
    #expect(box.snapshot(box.dst).keys.sorted() == [
        "Gone/Podcasts/kept.mp3", "Music/a.mp3", "Podcasts/already.mp3", "Rock/Studio/s.mp3",
    ])
}

@Test func systemFilesAreLeftAlone() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    try box.write(box.src, "a.txt", "a")
    try box.write(box.src, ".DS_Store", "x")
    try box.write(box.dst, ".Spotlight-V100/store.db", "x")
    try box.write(box.dst, ".fseventsd/log", "x")
    try box.write(box.dst, "._a.txt", "x")

    let run = try box.sync()
    #expect(run.plan.deletes.isEmpty)
    #expect(box.exists(box.dst, ".Spotlight-V100/store.db"))
    #expect(box.exists(box.dst, ".fseventsd/log"))
    #expect(box.exists(box.dst, "._a.txt"))
    #expect(!box.exists(box.dst, ".DS_Store"))
}

@Test func fileAndFolderSwapPlaces() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    try box.write(box.src, "x", "now a file")
    try box.write(box.src, "y/inner.txt", "now a folder")
    try box.write(box.dst, "x/old.txt", "was a folder")
    try box.write(box.dst, "y", "was a file")

    let run = try box.sync()
    #expect(run.result.errors.isEmpty)
    #expect(box.snapshot(box.dst) == box.snapshot(box.src))
}

@Test func cancelLeavesNoPartialFiles() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    try box.write(box.src, "a.txt", "a")
    try box.write(box.src, "b.txt", "b")
    let rules = ExcludeRules("")
    let plan = SyncEngine.makePlan(
        source: try SyncEngine.scan(root: box.src, rules: rules, isDestination: false),
        dest: try SyncEngine.scan(root: box.dst, rules: rules, isDestination: true))
    var calls = 0
    let result = SyncEngine.execute(plan: plan, source: box.src, dest: box.dst, isCancelled: {
        calls += 1
        return calls > 2
    })
    #expect(result.cancelled)
    let left = try box.fm.contentsOfDirectory(atPath: box.dst.path)
    #expect(!left.contains { $0.hasPrefix(".musicsync-tmp") })
}

@Test func mp3OnlyFilter() throws {
    let box = try Sandbox(); defer { box.cleanup() }
    try box.write(box.src, "Band/song.MP3", "a")
    try box.write(box.src, "Band/cover.jpg", "x")
    try box.write(box.src, "OnlyM4a/track.m4a", "x")
    try box.write(box.src, "loose.m4a", "x")
    try box.write(box.dst, "old.m4a", "x")
    try box.write(box.dst, "OnlyM4a/track.m4a", "x")
    let rules = ExcludeRules("")
    let s = try SyncEngine.scan(root: box.src, rules: rules, isDestination: false, onlyExtensions: ["mp3"])
    let d = try SyncEngine.scan(root: box.dst, rules: rules, isDestination: true)
    let plan = SyncEngine.makePlan(source: s, dest: d)
    let result = SyncEngine.execute(plan: plan, source: box.src, dest: box.dst)
    #expect(result.errors.isEmpty)
    #expect(box.snapshot(box.dst).keys.sorted() == ["Band/song.MP3"])
    #expect(!box.exists(box.dst, "OnlyM4a"))
    #expect(box.snapshot(box.src).count == 4)
}

@Test func excludeRuleParsing() {
    let rules = ExcludeRules("Podcasts, /Rock/Live/ ,,")
    #expect(rules.excludesFolder(relKey: "podcasts"))
    #expect(rules.excludesFolder(relKey: "a/b/podcasts"))
    #expect(rules.excludesFolder(relKey: "rock/live"))
    #expect(!rules.excludesFolder(relKey: "rock"))
    #expect(!rules.excludesFolder(relKey: "other/rock/live"))
}
