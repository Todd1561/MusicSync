import MusicSyncCore
import SwiftUI

struct OrganizeView: View {
    @ObservedObject var model: OrganizeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                folderRow("Source folder", path: model.sourcePath) { model.choose(source: true) }
                folderRow("Destination folder", path: model.destPath) { model.choose(source: false) }
            }
            .disabled(model.busy)

            Text("Files named “Band - Song” or “Song - Band” are moved to Destination/Band/Song. Check the table before moving.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Table(model.rows) {
                TableColumn("") { row in
                    Toggle("", isOn: model.binding(row.id).include)
                        .labelsHidden()
                        .disabled(row.band.isEmpty || row.song.isEmpty)
                }
                .width(22)
                TableColumn("Original file") { row in
                    Text(row.fileName).lineLimit(1).truncationMode(.middle).help(row.fileName)
                }
                TableColumn("Band") { row in
                    TextField("Band", text: model.binding(row.id).band)
                }
                TableColumn("") { row in
                    Button {
                        model.swap(row.id)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Swap band and song")
                }
                .width(24)
                TableColumn("Song") { row in
                    TextField("Song", text: model.binding(row.id).song)
                }
                TableColumn("Status") { row in
                    HStack(spacing: 4) {
                        if !row.confident {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Text(row.status)
                            .foregroundStyle(row.confident ? Color.secondary : Color.orange)
                            .lineLimit(1)
                            .help(row.status)
                    }
                }
                .width(min: 120, ideal: 170)
            }
            .frame(minHeight: 240, maxHeight: .infinity)
            .disabled(model.busy)

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: model.fraction)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Select All") { model.setAll(true) }
                Button("Select None") { model.setAll(false) }
                Spacer()
                Button("Scan") { model.scan() }
                    .disabled(!model.canScan)
                Button("Move \(model.includedCount) File\(model.includedCount == 1 ? "" : "s")") { model.move() }
                    .disabled(!model.canMove)
            }
            .disabled(model.busy)
        }
        .padding(20)
    }

    private func folderRow(_ label: String, path: String, choose: @escaping () -> Void) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            HStack {
                Text(path.isEmpty ? "No folder selected" : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(path)
                Button("Choose…", action: choose)
            }
        }
    }
}
