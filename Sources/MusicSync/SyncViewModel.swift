import AppKit
import Foundation
import MusicSyncCore

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@MainActor
final class SyncViewModel: ObservableObject {
    enum Phase { case idle, scanning, confirming, syncing }

    @Published var sourcePath: String { didSet { defaults.set(sourcePath, forKey: Keys.source) } }
    @Published var excludes: String { didSet { defaults.set(excludes, forKey: Keys.excludes) } }
    @Published var volumes: [ExternalVolume] = []
    @Published var selectedVolumeID: String? {
        didSet {
            if let v = volumes.first(where: { $0.id == selectedVolumeID }) {
                defaults.set(v.token, forKey: Keys.volume)
            }
        }
    }
    @Published var phase: Phase = .idle
    @Published var fraction: Double = 0
    @Published var status = "Ready."
    @Published var isError = false
    @Published var details: [String] = []
    @Published var pendingPlan: SyncPlan?
    @Published var ejecting = false
    /// Set once a drive has been ejected; shown as the "safe to remove" confirmation.
    @Published var ejectMessage: String?

    private enum Keys {
        static let source = "sourcePath"
        static let excludes = "excludes"
        static let volume = "lastVolumeUUID"
    }

    private let defaults = UserDefaults.standard
    private var cancelFlag = CancelFlag()
    private var job: (source: URL, dest: URL)?
    private var observers: [NSObjectProtocol] = []

    init() {
        sourcePath = defaults.string(forKey: Keys.source) ?? ""
        excludes = defaults.string(forKey: Keys.excludes) ?? ""
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            })
        }
    }

    var selectedVolume: ExternalVolume? { volumes.first { $0.id == selectedVolumeID } }
    var isBusy: Bool { phase != .idle }
    var canSync: Bool { phase == .idle && !ejecting && !sourcePath.isEmpty && selectedVolume != nil }
    var canEject: Bool { phase == .idle && !ejecting && selectedVolume != nil }

    func refreshVolumes() {
        volumes = Volumes.external()
        if selectedVolume == nil {
            let remembered = defaults.string(forKey: Keys.volume)
            selectedVolumeID = volumes.first { $0.token == remembered }?.id
        }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder to copy to the drive"
        if !sourcePath.isEmpty { panel.directoryURL = URL(fileURLWithPath: sourcePath) }
        if panel.runModal() == .OK, let url = panel.url { sourcePath = url.path }
    }

    // MARK: Eject

    func eject() {
        guard canEject, let volume = selectedVolume else { return }
        ejecting = true
        isError = false
        details = []
        status = "Ejecting \(volume.name)…"
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            } catch {
                failure = error.localizedDescription
            }
            // Only report success once the drive is really gone.
            if failure == nil, Volumes.external().contains(where: { $0.url == volume.url }) {
                failure = "The drive is still mounted."
            }
            let result = failure
            await self.ejected(volume.name, failure: result)
        }
    }

    private func ejected(_ name: String, failure: String?) {
        ejecting = false
        if let failure {
            status = "Could not eject \(name): \(failure) Do not remove it yet."
            isError = true
        } else {
            selectedVolumeID = nil
            status = "\(name) was ejected. It is safe to remove."
            ejectMessage = "“\(name)” has been ejected. It is now safe to remove the drive."
        }
        refreshVolumes()
    }

    // MARK: Sync

    func start() {
        guard phase == .idle, let volume = selectedVolume else { return }
        let source = URL(fileURLWithPath: sourcePath)
        let dest = volume.url
        details = []
        do {
            try Volumes.validate(source: source, destination: dest)
        } catch {
            finish(error.localizedDescription, error: true)
            return
        }
        let rules = ExcludeRules(excludes)
        let flag = CancelFlag()
        cancelFlag = flag
        job = (source, dest)
        phase = .scanning
        isError = false
        fraction = 0
        status = "Scanning…"

        Task.detached(priority: .userInitiated) {
            do {
                let s = try SyncEngine.scan(root: source, rules: rules, isDestination: false,
                                            onlyExtensions: ["mp3"]) { flag.isSet }
                let d = try SyncEngine.scan(root: dest, rules: rules, isDestination: true) { flag.isSet }
                let plan = SyncEngine.makePlan(source: s, dest: d)
                await self.scanned(plan)
            } catch is SyncCancelled {
                await self.finish("Cancelled.", error: false)
            } catch {
                await self.finish(error.localizedDescription, error: true)
            }
        }
    }

    private func scanned(_ plan: SyncPlan) {
        guard let job else { return }
        if plan.isEmpty {
            details = plan.warnings
            fraction = 1
            finish("Already in sync — \(plan.unchanged) files up to date.", error: false)
            return
        }
        if let free = Volumes.available(at: job.dest), plan.netBytesNeeded > free {
            details = plan.warnings
            finish("Not enough space on the drive: needs \(bytes(plan.netBytesNeeded)) more, \(bytes(free)) free.", error: true)
            return
        }
        if plan.deletes.isEmpty {
            run(plan)
        } else {
            pendingPlan = plan
            phase = .confirming
            status = "Waiting for confirmation…"
        }
    }

    func confirm() {
        guard phase == .confirming, let plan = pendingPlan else { return }
        pendingPlan = nil
        run(plan)
    }

    func decline() {
        guard phase == .confirming else { return }
        pendingPlan = nil
        finish("Cancelled. Nothing was changed.", error: false)
    }

    func cancel() {
        cancelFlag.set()
        if phase == .syncing || phase == .scanning { status = "Cancelling…" }
    }

    private func run(_ plan: SyncPlan) {
        guard let job else { return }
        let flag = cancelFlag
        phase = .syncing
        fraction = 0
        Task.detached(priority: .userInitiated) {
            var lastUpdate = Date.distantPast
            let result = SyncEngine.execute(plan: plan, source: job.source, dest: job.dest,
                                            isCancelled: { flag.isSet }) { p in
                let now = Date()
                guard now.timeIntervalSince(lastUpdate) > 0.1 else { return }
                lastUpdate = now
                Task { @MainActor in self.show(p) }
            }
            await self.completed(result, plan: plan)
        }
    }

    private func show(_ p: SyncProgress) {
        guard phase == .syncing, !cancelFlag.isSet else { return }
        if p.deleting {
            status = "Deleting \(p.currentPath)"
        } else {
            fraction = p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0
            let n = min(p.filesDone + 1, p.filesTotal)
            status = "Copying file \(n) of \(p.filesTotal): \(p.currentPath) — \(bytes(p.bytesDone)) of \(bytes(p.bytesTotal)) done"
        }
    }

    private func completed(_ r: SyncResult, plan: SyncPlan) {
        var lines = plan.warnings
        if !r.errors.isEmpty {
            lines.append("\(r.errors.count) item(s) failed:")
            lines.append(contentsOf: r.errors)
        }
        details = lines
        let summary = "\(r.copiedFiles) copied (\(bytes(r.copiedBytes))), "
            + "\(r.deletedFiles + r.deletedFolders) deleted, \(plan.unchanged) unchanged"
        if let reason = r.aborted {
            finish("Stopped: \(reason) \(summary).", error: true)
        } else if r.cancelled {
            finish("Cancelled part-way: \(summary).", error: false)
        } else if !r.errors.isEmpty {
            finish("Finished with errors: \(summary).", error: true)
        } else {
            fraction = 1
            finish("Done: \(summary).", error: false)
        }
        refreshVolumes()
    }

    private func finish(_ message: String, error: Bool) {
        phase = .idle
        status = message
        isError = error
    }

    func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
