import Foundation

public struct ExternalVolume: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let uuid: String?
    public let available: Int64
    public let total: Int64

    public var id: String { url.path }
    /// Stable value used to recognise the same drive on the next launch.
    public var token: String { uuid ?? name }
}

public struct VolumeError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum Volumes {
    /// Writable, locally attached volumes that are not the Mac's internal disk.
    public static func external() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
            .volumeIsRootFileSystemKey, .volumeUUIDStringKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [ExternalVolume] = []
        for url in urls {
            guard url.path.hasPrefix("/Volumes/"),
                  let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.volumeIsInternal == true || v.volumeIsRootFileSystem == true { continue }
            if v.volumeIsLocal == false || v.volumeIsReadOnly == true { continue }
            result.append(ExternalVolume(
                url: url,
                name: v.volumeName ?? url.lastPathComponent,
                uuid: v.volumeUUIDString,
                available: Int64(v.volumeAvailableCapacity ?? 0),
                total: Int64(v.volumeTotalCapacity ?? 0)))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func available(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
    }

    private static func volumeURL(of url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL
    }

    /// Re-checked right before every sync: the destination must be a mounted
    /// external drive, and the source must not be on it.
    public static func validate(source: URL, destination: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw VolumeError(message: "The source folder no longer exists.")
        }
        guard external().contains(where: { $0.url.standardizedFileURL == destination.standardizedFileURL }) else {
            throw VolumeError(message: "The destination drive is no longer connected.")
        }
        guard let destVol = volumeURL(of: destination), let rootVol = volumeURL(of: URL(fileURLWithPath: "/")),
              destVol != rootVol else {
            throw VolumeError(message: "The destination cannot be this Mac's internal disk.")
        }
        if volumeURL(of: source) == destVol {
            throw VolumeError(message: "The source folder is on the destination drive. Choose a folder on another disk.")
        }
    }
}
