import AVFoundation
import AppKit
import MusicSyncCore
import SwiftUI

@MainActor
final class OrganizeViewModel: ObservableObject {
    @Published var sourcePath: String { didSet { defaults.set(sourcePath, forKey: "organizeSource") } }
    @Published var destPath: String { didSet { defaults.set(destPath, forKey: "organizeDest") } }
    @Published var rows: [OrganizeRow] = []
    @Published var busy = false
    @Published var fraction: Double = 0
    @Published var status = "Choose the folders, then Scan."
    @Published var isError = false

    private let defaults = UserDefaults.standard
    private var existingBands: [String] = []
    /// The folders the current table was scanned from.
    private var scanned: (source: URL, dest: URL)?

    init() {
        sourcePath = defaults.string(forKey: "organizeSource") ?? ""
        destPath = defaults.string(forKey: "organizeDest") ?? ""
    }

    var canScan: Bool { !busy && !sourcePath.isEmpty && !destPath.isEmpty }
    var includedCount: Int { rows.filter(\.include).count }
    var canMove: Bool { !busy && includedCount > 0 }

    func choose(source: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = !source
        panel.prompt = "Choose"
        panel.message = source ? "Choose the folder of files to organize" : "Choose the folder to move them into"
        let current = source ? sourcePath : destPath
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if source { sourcePath = url.path } else { destPath = url.path }
        rows = []
        scanned = nil
    }

    func binding(_ id: Int) -> Binding<OrganizeRow> {
        Binding(
            get: { self.rows.first { $0.id == id } ?? OrganizeRow(id: id, fileName: "", ext: "", band: "", song: "", include: false, confident: false, status: "") },
            set: { new in if let i = self.rows.firstIndex(where: { $0.id == id }) { self.rows[i] = new } })
    }

    func swap(_ id: Int) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let band = rows[i].band
        rows[i].band = rows[i].song
        rows[i].song = band
        rows[i].status = "Swapped"
        rows[i].confident = true
        rows[i].include = !rows[i].band.isEmpty && !rows[i].song.isEmpty
    }

    func setAll(_ include: Bool) {
        for i in rows.indices { rows[i].include = include && !rows[i].band.isEmpty && !rows[i].song.isEmpty }
    }

    private func fail(_ message: String) {
        busy = false
        status = message
        isError = true
    }

    // MARK: Scan

    func scan() {
        guard canScan else { return }
        let source = URL(fileURLWithPath: sourcePath), dest = URL(fileURLWithPath: destPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            return fail("The source folder does not exist.")
        }
        guard FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue else {
            return fail("The destination folder does not exist.")
        }
        guard source.standardizedFileURL != dest.standardizedFileURL else {
            return fail("Source and destination must be different folders.")
        }
        busy = true
        isError = false
        fraction = 0
        rows = []
        status = "Scanning…"

        Task {
            let names: [String]
            do {
                names = try await Task.detached { try Organizer.listAudioFiles(in: source) }.value
            } catch {
                return fail(error.localizedDescription)
            }
            let bands = await Task.detached { Organizer.listFolders(in: dest) }.value
            var tags: [String: TrackTags] = [:]
            for (i, name) in names.enumerated() {
                status = "Reading tags: \(i + 1) of \(names.count)"
                fraction = Double(i + 1) / Double(max(names.count, 1))
                tags[name] = await Self.readTags(source.appendingPathComponent(name))
            }
            existingBands = bands
            scanned = (source, dest)
            rows = Organizer.analyze(fileNames: names, existingBands: bands, tags: tags)
            busy = false
            fraction = 0
            let unsure = rows.filter { !$0.confident }.count
            status = names.isEmpty
                ? "No .mp3 files found in the source folder."
                : "\(names.count) file(s) found" + (unsure > 0 ? " — \(unsure) need checking (unticked)." : ".")
        }
    }

    private nonisolated static func readTags(_ url: URL) async -> TrackTags {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return TrackTags() }
        func value(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
                  let s = try? await item.load(.stringValue) else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return TrackTags(artist: await value(.commonIdentifierArtist), title: await value(.commonIdentifierTitle))
    }

    // MARK: Move

    func move() {
        guard canMove, let scanned else { return }
        let todo = rows.filter(\.include)
        let bands = existingBands
        busy = true
        isError = false
        fraction = 0

        Task {
            var outcomes: [Int: MoveOutcome] = [:]
            var known = bands
            for (i, row) in todo.enumerated() {
                status = "Moving \(i + 1) of \(todo.count): \(row.fileName)"
                let folders = known
                let outcome = await Task.detached {
                    Organizer.move(row: row, source: scanned.source, dest: scanned.dest, existingBands: folders)
                }.value
                outcomes[row.id] = outcome
                if outcome == .moved, !known.contains(row.band) { known.append(Organizer.sanitize(row.band)) }
                fraction = Double(i + 1) / Double(todo.count)
            }
            existingBands = known

            var moved = 0, exists = 0, failed = 0
            var remaining: [OrganizeRow] = []
            for var row in rows {
                switch outcomes[row.id] {
                case .moved:
                    moved += 1
                    continue
                case .exists:
                    exists += 1
                    row.status = "Already exists — not moved"
                    row.include = false
                    row.confident = false
                case .failed(let why):
                    failed += 1
                    row.status = "Failed: \(why)"
                    row.include = false
                    row.confident = false
                case nil:
                    break
                }
                remaining.append(row)
            }
            rows = remaining
            busy = false
            var parts = ["Moved \(moved) file(s)"]
            if exists > 0 { parts.append("\(exists) already existed") }
            if failed > 0 { parts.append("\(failed) failed") }
            if !remaining.isEmpty { parts.append("\(remaining.count) left in the source") }
            status = parts.joined(separator: ", ") + "."
            isError = failed > 0
        }
    }
}
