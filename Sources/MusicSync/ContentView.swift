import MusicSyncCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var sync: SyncViewModel
    @ObservedObject var organize: OrganizeViewModel

    var body: some View {
        TabView {
            OrganizeView(model: organize)
                .tabItem { Text("Organize") }
            VStack(spacing: 0) {
                StickSyncView(model: sync)
                Spacer(minLength: 0)
            }
            .tabItem { Text("Stick Sync") }
        }
        .padding(12)
        .frame(minWidth: 760, idealWidth: 1140, maxWidth: .infinity, minHeight: 520, idealHeight: 840, maxHeight: .infinity)
    }
}

struct StickSyncView: View {
    @ObservedObject var model: SyncViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("Source folder").gridColumnAlignment(.trailing)
                    HStack {
                        Text(model.sourcePath.isEmpty ? "No folder selected" : model.sourcePath)
                            .foregroundStyle(model.sourcePath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(model.sourcePath)
                        Button("Choose…") { model.chooseSource() }
                    }
                }
                GridRow {
                    Text("Destination drive")
                    HStack {
                        Picker("", selection: $model.selectedVolumeID) {
                            Text(model.volumes.isEmpty ? "No external drives connected" : "Select a drive…")
                                .tag(String?.none)
                            ForEach(model.volumes) { v in
                                Text("\(v.name) — \(model.bytes(v.available)) free of \(model.bytes(v.total))")
                                    .tag(String?.some(v.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        Button {
                            model.refreshVolumes()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh the list of drives")
                        Button {
                            model.eject()
                        } label: {
                            Label("Eject", systemImage: "eject.fill")
                        }
                        .disabled(!model.canEject)
                        .help("Eject the selected drive so it can be unplugged")
                    }
                }
                GridRow {
                    Text("Exclude folders")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("e.g. Podcasts, Audiobooks, Rock/Live", text: $model.excludes)
                            .textFieldStyle(.roundedBorder)
                        Text("Comma-separated folder names. Excluded folders are not copied and are left alone on the drive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(model.isBusy)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if model.phase == .scanning {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: model.fraction)
                }
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            }

            if !model.details.isEmpty {
                ScrollView {
                    Text(model.details.joined(separator: "\n"))
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 90)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Text("The drive is made to match the .mp3 files in the source folder. The source is never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.phase == .scanning || model.phase == .syncing {
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Sync") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSync)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .alert("Safe to Remove", isPresented: Binding(
            get: { model.ejectMessage != nil },
            set: { if !$0 { model.ejectMessage = nil } })
        ) {
            Button("OK") { model.ejectMessage = nil }
        } message: {
            Text(model.ejectMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { model.phase == .confirming },
            set: { if !$0 { model.decline() } })
        ) {
            if let plan = model.pendingPlan {
                ConfirmSheet(model: model, plan: plan)
            }
        }
    }
}

struct ConfirmSheet: View {
    @ObservedObject var model: SyncViewModel
    let plan: SyncPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete items from \(model.selectedVolume?.name ?? "the drive")?")
                .font(.headline)
            Text("\(plan.deletedFileCount) file(s) and \(plan.deletedFolderCount) folder(s) on the drive are not in the source folder and will be permanently deleted (\(model.bytes(plan.bytesToFree))). \(plan.copies.count) file(s) will be copied (\(model.bytes(plan.bytesToCopy))).")
                .fixedSize(horizontal: false, vertical: true)
            if plan.sourceFileCount == 0 {
                Text("The source folder contains no files — continuing will empty the drive.")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(plan.deleteDisplay, id: \.self) { path in
                Text(path).font(.callout).lineLimit(1).truncationMode(.middle)
            }
            .frame(height: 220)
            .border(.separator)
            HStack {
                Spacer()
                Button("Cancel") { model.decline() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete and Sync") { model.confirm() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
