import Foundation

public struct TrackTags: Sendable {
    public var artist: String?
    public var title: String?
    public init(artist: String? = nil, title: String? = nil) {
        self.artist = artist
        self.title = title
    }
}

public struct OrganizeRow: Identifiable, Sendable {
    public let id: Int
    public let fileName: String
    public let ext: String
    public var band: String
    public var song: String
    /// Whether the row will be moved.
    public var include: Bool
    /// False when the band/song order is only a guess.
    public var confident: Bool
    public var status: String

    public init(id: Int, fileName: String, ext: String, band: String, song: String,
                include: Bool, confident: Bool, status: String) {
        self.id = id
        self.fileName = fileName
        self.ext = ext
        self.band = band
        self.song = song
        self.include = include
        self.confident = confident
        self.status = status
    }
}

public enum MoveOutcome: Sendable, Equatable {
    case moved
    case exists
    case failed(String)
}

public enum Organizer {
    public static let audioExtensions: Set<String> = ["mp3"]

    // MARK: Names

    /// Comparison key: ignores case, accents, punctuation and a leading "The",
    /// so "AC/DC", "AC_DC" and "ac-dc" are the same band.
    public static func matchKey(_ s: String) -> String {
        let folded = s.replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        var words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.count > 1, words.first == "the" { words.removeFirst() }
        return words.joined()
    }

    /// Makes a name safe to use as a file or folder name.
    public static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        while s.hasPrefix(".") { s.removeFirst() }
        return s
    }

    /// Every way of cutting a filename (without extension) into two sides at a hyphen.
    public static func splits(_ stem: String) -> [(left: String, right: String)] {
        let s = stem.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let separator = s.contains(" - ") ? " - " : "-"
        var parts = s.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // "01 - Band - Song": drop the track number.
        if parts.count > 2, let first = parts.first, first.allSatisfy(\.isNumber) { parts.removeFirst() }
        guard parts.count >= 2 else { return [] }
        return (1..<parts.count).map { i in
            (parts[..<i].joined(separator: separator), parts[i...].joined(separator: separator))
        }
    }

    // MARK: Detection

    /// Works out band and song for each file.
    /// - Parameters:
    ///   - existingBands: folder names already in the destination.
    ///   - tags: embedded artist/title per file name, where available.
    public static func analyze(fileNames: [String], existingBands: [String],
                               tags: [String: TrackTags] = [:]) -> [OrganizeRow] {
        var existing: [String: String] = [:]
        for b in existingBands {
            let k = matchKey(b)
            if !k.isEmpty, existing[k] == nil { existing[k] = b }
        }

        struct Parsed { let name: String; let stem: String; let ext: String; let cands: [(left: String, right: String)] }
        let parsed: [Parsed] = fileNames.map { name in
            let ns = name as NSString
            let stem = ns.deletingPathExtension
            return Parsed(name: name, stem: stem, ext: ns.pathExtension, cands: splits(stem))
        }

        // How many files each candidate side appears in.
        var freq: [String: Int] = [:]
        for p in parsed {
            var seen = Set<String>()
            for c in p.cands {
                for side in [c.left, c.right] {
                    let k = matchKey(side)
                    if !k.isEmpty { seen.insert(k) }
                }
            }
            for k in seen { freq[k, default: 0] += 1 }
        }

        var spelling: [String: String] = [:]   // first spelling seen in this batch, per band
        var rows: [OrganizeRow] = []
        for (i, p) in parsed.enumerated() {
            guard !p.cands.isEmpty else {
                rows.append(OrganizeRow(id: i, fileName: p.name, ext: p.ext, band: "", song: p.stem,
                                        include: false, confident: false, status: "No hyphen — enter a band"))
                continue
            }
            let tag = tags[p.name] ?? TrackTags()
            let artistKey = tag.artist.map(matchKey) ?? ""
            let titleKey = tag.title.map(matchKey) ?? ""

            struct Option { let band: String; let song: String; let score: Int; let why: String }
            var options: [Option] = []
            for c in p.cands {
                // "Song - Band" is listed first so it wins when nothing else decides.
                for (band, song) in [(c.right, c.left), (c.left, c.right)] {
                    let bk = matchKey(band), sk = matchKey(song)
                    var score = 0
                    var why = ""
                    if !bk.isEmpty, bk == artistKey {
                        score += 100; why = "Matches tag"
                    } else if !sk.isEmpty, sk == titleKey {
                        score += 50; why = "Matches tag"
                    }
                    if existing[bk] != nil {
                        score += 60
                        if why.isEmpty { why = "Existing folder" }
                    }
                    let n = freq[bk] ?? 0
                    if n >= 2 {
                        score += 10 + min(n, 20)
                        if why.isEmpty { why = "Band seen in \(n) files" }
                    }
                    options.append(Option(band: band, song: song, score: score, why: why))
                }
            }
            // Stable: on equal scores the earlier option ("Song - Band", first hyphen) wins.
            let ranked = options.enumerated().sorted {
                $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
            }.map(\.element)
            let best = ranked[0]
            let tied = ranked.count > 1 && ranked[1].score == best.score
            let confident = best.score > 0 && !tied
            let status = best.score == 0 ? "Guess — check order" : (tied ? "Unclear — check order" : best.why)

            let bk = matchKey(best.band)
            let band: String
            if let folder = existing[bk] {
                band = folder
            } else if confident {
                if spelling[bk] == nil { spelling[bk] = best.band }
                band = spelling[bk] ?? best.band
            } else {
                band = best.band
            }
            rows.append(OrganizeRow(id: i, fileName: p.name, ext: p.ext, band: band, song: best.song,
                                    include: confident, confident: confident, status: status))
        }
        return rows
    }

    // MARK: Files

    /// Audio files directly inside `folder` (sub-folders are not searched).
    public static func listAudioFiles(in folder: URL) throws -> [String] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return urls.filter {
            audioExtensions.contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        .map(\.lastPathComponent)
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func listFolders(in folder: URL) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
    }

    /// Where a row's file will end up, reusing an existing band folder's spelling.
    public static func target(dest: URL, band: String, song: String, ext: String,
                              existingBands: [String]) -> URL? {
        let b = sanitize(band), s = sanitize(song)
        guard !b.isEmpty, !s.isEmpty else { return nil }
        let key = matchKey(b)
        let folder = existingBands.first { !key.isEmpty && matchKey($0) == key } ?? b
        let file = ext.isEmpty ? s : s + "." + ext
        return dest.appendingPathComponent(folder).appendingPathComponent(file)
    }

    /// Moves one file into `dest/Band/Song.ext`. Never overwrites.
    public static func move(row: OrganizeRow, source: URL, dest: URL, existingBands: [String]) -> MoveOutcome {
        let fm = FileManager.default
        guard let target = target(dest: dest, band: row.band, song: row.song, ext: row.ext,
                                  existingBands: existingBands) else {
            return .failed("Needs a band and a song")
        }
        if fm.fileExists(atPath: target.path) { return .exists }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source.appendingPathComponent(row.fileName), to: target)
            return .moved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
