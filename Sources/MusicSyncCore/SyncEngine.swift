import Foundation

public struct Entry: Sendable {
    public let relPath: String
    public let isDir: Bool
    public let size: Int64
    public let mtime: Date
}

public struct ScanResult: Sendable {
    /// Keyed by `syncKey(relPath)`.
    public var entries: [String: Entry] = [:]
    /// Folders that contain an excluded folder (or could not be read) and so must not be removed.
    public var protectedDirs: Set<String> = []
    public var warnings: [String] = []
    public var fileCount: Int { entries.values.reduce(0) { $0 + ($1.isDir ? 0 : 1) } }
}

public struct CopyItem: Sendable {
    public let srcRel: String
    public let dstRel: String
    public let size: Int64
    public let mtime: Date
}

public struct DeleteItem: Sendable {
    public let relPath: String
    public let isDir: Bool
    public let size: Int64
}

public struct SyncPlan: Sendable {
    public var dirsToCreate: [String] = []
    public var copies: [CopyItem] = []
    public var deletes: [DeleteItem] = []
    /// Top-most deleted items only, for showing to the user (folders end in "/").
    public var deleteDisplay: [String] = []
    public var bytesToCopy: Int64 = 0
    public var bytesToFree: Int64 = 0
    public var bytesReplaced: Int64 = 0
    public var unchanged = 0
    public var sourceFileCount = 0
    public var warnings: [String] = []

    public var deletedFileCount: Int { deletes.filter { !$0.isDir }.count }
    public var deletedFolderCount: Int { deletes.filter { $0.isDir }.count }
    public var isEmpty: Bool { dirsToCreate.isEmpty && copies.isEmpty && deletes.isEmpty }
    /// Extra space the drive needs, after deletions and replaced files are accounted for.
    public var netBytesNeeded: Int64 { bytesToCopy - bytesToFree - bytesReplaced }
}

public struct SyncProgress: Sendable {
    public var currentPath = ""
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var filesDone = 0
    public var filesTotal = 0
    public var deleting = false
}

public struct SyncResult: Sendable {
    public var copiedFiles = 0
    public var copiedBytes: Int64 = 0
    public var deletedFiles = 0
    public var deletedFolders = 0
    public var errors: [String] = []
    public var cancelled = false
    /// Set when the sync had to stop early (drive unplugged, drive full).
    public var aborted: String?
}

public struct SyncCancelled: Error {}

public struct ScanError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum SyncEngine {
    /// Modification times within this many seconds count as equal (FAT stores 2-second steps).
    static let mtimeTolerance: TimeInterval = 2
    static let chunkSize = 1 << 20

    // MARK: Scan

    /// - Parameter onlyExtensions: when set, only files with these (lowercase)
    ///   extensions are included, and folders left with no such files are dropped.
    public static func scan(root: URL, rules: ExcludeRules, isDestination: Bool,
                            onlyExtensions: Set<String>? = nil,
                            isCancelled: () -> Bool = { false }) throws -> ScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                      .fileSizeKey, .contentModificationDateKey]
        var result = ScanResult()
        var stack: [(url: URL, rel: String)] = [(root, "")]

        while let (dirURL, dirRel) = stack.popLast() {
            if isCancelled() { throw SyncCancelled() }
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: keys, options: [])
            } catch {
                // An unreadable source folder must stop the sync: treating it as
                // empty would delete its contents from the drive.
                if !isDestination || dirRel.isEmpty {
                    throw ScanError(message: "Cannot read \(dirRel.isEmpty ? dirURL.path : dirRel): \(error.localizedDescription)")
                }
                result.warnings.append("Could not read \(dirRel) on the drive; left untouched.")
                protect(dirRel, includingSelf: true, in: &result)
                continue
            }
            for child in children {
                let name = child.lastPathComponent
                if ExcludeRules.isIgnored(name: name, atRoot: dirRel.isEmpty) { continue }
                let rel = dirRel.isEmpty ? name : dirRel + "/" + name
                let key = syncKey(rel)
                guard let v = try? child.resourceValues(forKeys: Set(keys)) else {
                    if !isDestination { throw ScanError(message: "Cannot read \(rel).") }
                    protect(rel, includingSelf: false, in: &result)
                    continue
                }
                let mtime = v.contentModificationDate ?? .distantPast
                if v.isSymbolicLink == true {
                    if isDestination {
                        result.entries[key] = Entry(relPath: rel, isDir: false, size: 0, mtime: mtime)
                    } else {
                        result.warnings.append("Skipped link: \(rel)")
                    }
                } else if v.isDirectory == true {
                    if rules.excludesFolder(relKey: key) {
                        protect(rel, includingSelf: false, in: &result)
                        continue
                    }
                    if result.entries[key] != nil {
                        result.warnings.append("Skipped \(rel): another item has the same name in different case.")
                        continue
                    }
                    result.entries[key] = Entry(relPath: rel, isDir: true, size: 0, mtime: mtime)
                    stack.append((child, rel))
                } else if v.isRegularFile == true {
                    if let onlyExtensions, !onlyExtensions.contains(child.pathExtension.lowercased()) { continue }
                    if result.entries[key] != nil {
                        result.warnings.append("Skipped \(rel): another item has the same name in different case.")
                        continue
                    }
                    result.entries[key] = Entry(relPath: rel, isDir: false, size: Int64(v.fileSize ?? 0), mtime: mtime)
                }
            }
        }
        if onlyExtensions != nil {
            // Drop folders that ended up with no wanted files anywhere inside them.
            var needed = Set<String>()
            for (key, entry) in result.entries where !entry.isDir {
                var k = key
                while let slash = k.lastIndex(of: "/") {
                    k = String(k[..<slash])
                    if !needed.insert(k).inserted { break }
                }
            }
            result.entries = result.entries.filter { !$0.value.isDir || needed.contains($0.key) }
        }
        return result
    }

    /// Marks every ancestor of `rel` (and optionally `rel` itself) as not removable.
    private static func protect(_ rel: String, includingSelf: Bool, in result: inout ScanResult) {
        var parts = syncKey(rel).split(separator: "/").map(String.init)
        if !includingSelf { parts.removeLast() }
        while !parts.isEmpty {
            result.protectedDirs.insert(parts.joined(separator: "/"))
            parts.removeLast()
        }
    }

    // MARK: Plan

    public static func makePlan(source: ScanResult, dest: ScanResult) -> SyncPlan {
        var plan = SyncPlan()
        plan.warnings = source.warnings + dest.warnings
        plan.sourceFileCount = source.fileCount

        // Where a source item lands on the drive, reusing the drive's existing
        // spelling of parent folders so no case-variant duplicates are created.
        var destRelCache: [String: String] = [:]
        func destRel(_ key: String) -> String {
            if let cached = destRelCache[key] { return cached }
            guard let src = source.entries[key] else { return key }
            let value: String
            if let d = dest.entries[key], d.isDir == src.isDir {
                value = d.relPath
            } else {
                let name = src.relPath.split(separator: "/").last.map(String.init) ?? src.relPath
                if let slash = key.lastIndex(of: "/") {
                    value = destRel(String(key[..<slash])) + "/" + name
                } else {
                    value = name
                }
            }
            destRelCache[key] = value
            return value
        }

        var deleteKeys = Set<String>()
        var deleteDirKeys = Set<String>()
        func addDelete(_ key: String, _ d: Entry) {
            guard deleteKeys.insert(key).inserted else { return }
            if d.isDir {
                if dest.protectedDirs.contains(key) { return }
                deleteDirKeys.insert(key)
            } else {
                plan.bytesToFree += d.size
            }
            plan.deletes.append(DeleteItem(relPath: d.relPath, isDir: d.isDir, size: d.size))
        }

        for key in source.entries.keys.sorted() {
            let s = source.entries[key]!
            let d = dest.entries[key]
            if s.isDir {
                if let d, d.isDir { continue }
                if let d { addDelete(key, d) }
                plan.dirsToCreate.append(destRel(key))
            } else {
                if let d, d.isDir {
                    if dest.protectedDirs.contains(key) {
                        plan.warnings.append("Skipped \(s.relPath): the drive has a folder with that name containing an excluded folder.")
                        continue
                    }
                    addDelete(key, d)
                } else if let d {
                    // FAT drives store local time with no time zone, so every
                    // timestamp reads exactly one hour off after a daylight-saving
                    // change. Same size and exactly an hour apart counts as unchanged.
                    let diff = abs(d.mtime.timeIntervalSince(s.mtime))
                    if d.size == s.size && (diff <= mtimeTolerance || abs(diff - 3600) <= mtimeTolerance) {
                        plan.unchanged += 1
                        continue
                    }
                    plan.bytesReplaced += d.size
                }
                plan.copies.append(CopyItem(srcRel: s.relPath, dstRel: destRel(key), size: s.size, mtime: s.mtime))
                plan.bytesToCopy += s.size
            }
        }

        for key in dest.entries.keys.sorted() where source.entries[key] == nil {
            addDelete(key, dest.entries[key]!)
        }

        plan.dirsToCreate.sort { depth($0) < depth($1) }
        for item in plan.deletes {
            let key = syncKey(item.relPath)
            if let slash = key.lastIndex(of: "/"), deleteDirKeys.contains(String(key[..<slash])) { continue }
            plan.deleteDisplay.append(item.isDir ? item.relPath + "/" : item.relPath)
        }
        plan.deleteDisplay.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return plan
    }

    private static func depth(_ rel: String) -> Int { rel.reduce(0) { $0 + ($1 == "/" ? 1 : 0) } }

    // MARK: Execute

    /// Applies the plan. Only ever reads from `source`.
    public static func execute(plan: SyncPlan, source: URL, dest: URL,
                               isCancelled: () -> Bool = { false },
                               progress: (SyncProgress) -> Void = { _ in }) -> SyncResult {
        let fm = FileManager.default
        var result = SyncResult()
        var p = SyncProgress()
        p.bytesTotal = plan.bytesToCopy
        p.filesTotal = plan.copies.count

        func driveGone() -> Bool { !fm.fileExists(atPath: dest.path) }
        func record(_ rel: String, _ error: Error) {
            result.errors.append("\(rel): \(error.localizedDescription)")
            if driveGone() {
                result.aborted = "The drive was disconnected."
            } else if (error as NSError).code == NSFileWriteOutOfSpaceError {
                result.aborted = "The drive is full."
            }
        }

        // 1. Deletions first, to free space: files, then folders deepest-first.
        p.deleting = true
        let files = plan.deletes.filter { !$0.isDir }
        let dirs = plan.deletes.filter { $0.isDir }.sorted { depth($0.relPath) > depth($1.relPath) }
        for item in files + dirs {
            if isCancelled() { result.cancelled = true; return result }
            p.currentPath = item.relPath
            progress(p)
            let url = dest.appendingPathComponent(item.relPath)
            do {
                try fm.removeItem(at: url)
                if item.isDir { result.deletedFolders += 1 } else { result.deletedFiles += 1 }
            } catch {
                if !fm.fileExists(atPath: url.path) { continue }
                record(item.relPath, error)
                if result.aborted != nil { return result }
            }
        }
        p.deleting = false

        // 2. Folders (including empty ones).
        for rel in plan.dirsToCreate {
            if isCancelled() { result.cancelled = true; return result }
            do {
                try fm.createDirectory(at: dest.appendingPathComponent(rel), withIntermediateDirectories: true)
            } catch {
                record(rel, error)
                if result.aborted != nil { return result }
            }
        }

        // 3. Files.
        for item in plan.copies {
            if isCancelled() { result.cancelled = true; return result }
            let base = p.bytesDone
            p.currentPath = item.srcRel
            progress(p)
            do {
                try copyFile(from: source.appendingPathComponent(item.srcRel),
                             to: dest.appendingPathComponent(item.dstRel),
                             mtime: item.mtime, isCancelled: isCancelled) { n in
                    p.bytesDone = min(base + item.size, p.bytesDone + Int64(n))
                    progress(p)
                }
                result.copiedFiles += 1
                result.copiedBytes += item.size
            } catch is SyncCancelled {
                result.cancelled = true
                return result
            } catch {
                record(item.srcRel, error)
                if result.aborted != nil { return result }
            }
            p.bytesDone = base + item.size
            p.filesDone += 1
            progress(p)
        }
        return result
    }

    /// Copies to a temporary name and renames into place, so an interrupted
    /// copy never leaves a partial file under the real name.
    private static func copyFile(from src: URL, to dst: URL, mtime: Date,
                                 isCancelled: () -> Bool, onBytes: (Int) -> Void) throws {
        let fm = FileManager.default
        let dir = dst.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".musicsync-tmp-\(UUID().uuidString)")

        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        var finished = false
        defer { if !finished { try? fm.removeItem(at: tmp) } }

        let output = try FileHandle(forWritingTo: tmp)
        do {
            while true {
                if isCancelled() { throw SyncCancelled() }
                let n: Int = try autoreleasepool {
                    guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { return 0 }
                    try output.write(contentsOf: data)
                    return data.count
                }
                if n == 0 { break }
                onBytes(n)
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: tmp, to: dst)
        finished = true
    }
}
