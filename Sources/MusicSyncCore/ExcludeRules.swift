import Foundation

/// Normalises a name or relative path so that the same file compares equal on
/// APFS (case-preserving, any Unicode form) and exFAT/FAT (case-insensitive).
public func syncKey(_ s: String) -> String {
    s.precomposedStringWithCanonicalMapping.lowercased()
}

/// The user's comma-separated list of folders to leave out of the sync.
///
/// - A plain name (`Podcasts`) matches a folder with that name at any depth.
/// - An entry containing `/` (`Rock/Live`) matches that path relative to the root.
public struct ExcludeRules: Sendable {
    public let names: Set<String>
    public let paths: Set<String>

    public init(_ text: String) {
        var names = Set<String>()
        var paths = Set<String>()
        for raw in text.split(separator: ",") {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !entry.isEmpty else { continue }
            let key = syncKey(entry)
            if key.contains("/") { paths.insert(key) } else { names.insert(key) }
        }
        self.names = names
        self.paths = paths
    }

    /// `relKey` is the folder's normalised path relative to the sync root.
    public func excludesFolder(relKey: String) -> Bool {
        if paths.contains(relKey) { return true }
        let name = relKey.split(separator: "/").last.map(String.init) ?? relKey
        return names.contains(name)
    }

    private static let rootSystemNames: Set<String> = [
        ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems",
        ".documentrevisions-v100", "system volume information", "$recycle.bin",
    ]

    /// Housekeeping files that are never copied and never deleted.
    public static func isIgnored(name: String, atRoot: Bool) -> Bool {
        if name == ".DS_Store" || name.hasPrefix("._") { return true }
        return atRoot && rootSystemNames.contains(name.lowercased())
    }
}
