import SwiftUI

/// Storage UIKit pieces (DESIGN §2.28 Space Map variant, §2.29 table checkbox, §3.12 toast with actions).
/// Deterministic sample data only; sizes are chosen for the Storage page's content width.
@MainActor enum GalleryStorage {
    static var items: [TTGallery.Item] {
        [
            .init(id: "space-map", size: CGSize(width: 760, height: 190)) { AnyView(SpaceMapSample(restricted: false)) },
            .init(id: "space-map-restricted", size: CGSize(width: 760, height: 190)) { AnyView(SpaceMapSample(restricted: true)) },
            .init(id: "table-checkbox", size: CGSize(width: 520, height: 210)) { AnyView(CheckboxTableSample()) },
            .init(id: "toast-actions", size: CGSize(width: 560, height: 40)) { AnyView(ToastActionsSample()) },
        ]
    }
}

private func gb(_ v: Double) -> Double { v * 1_000_000_000 }

private struct SpaceMapSample: View {
    let restricted: Bool

    var tiles: [TTSpaceMapTile] {
        func t(_ id: Int32, _ name: String, _ g: Double) -> TTSpaceMapTile {
            TTSpaceMapTile(id: id, value: gb(g), label: name, valueText: TTFormat.bytes(UInt64(gb(g))))
        }
        var out = [t(1, "Applications", 120), t(2, "Library", 64), t(3, "Users", 38), t(4, "System", 22),
                   t(5, "private", 9), t(6, "opt", 3.1)]
        if restricted {
            out += [TTSpaceMapTile(id: 7, value: gb(16), label: "com.apple.TCC", valueText: "—", kind: .restricted),
                    TTSpaceMapTile(id: 8, value: gb(11), label: "Mobile Documents", valueText: "—", kind: .restricted)]
        }
        out += [t(9, "usr", 1.2), t(10, "var", 0.6)] + (11...22).map { t(Int32($0), "item\($0)", 0.05) }
        return out.sorted { $0.value > $1.value }
    }

    var body: some View {
        TTSpaceMap(tiles, hoveredID: .constant(restricted ? nil : 2), onDrill: { _ in })
            .padding(12)
            .background(TTColor.bgCard)
    }
}

private struct CheckRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let size: String
    let state: TTTableCheckbox.CheckState
    let disabledReason: String?
}

private struct CheckboxTableSample: View {
    static let rows = [
        CheckRow(name: "Xcode caches", size: "12.4 GB", state: .on, disabledReason: nil),
        CheckRow(name: "Browser caches", size: "3.1 GB", state: .mixed, disabledReason: nil),
        CheckRow(name: "Old downloads", size: "820 MB", state: .off, disabledReason: nil),
        CheckRow(name: "Docker images", size: "18.0 GB", state: .off, disabledReason: "Docker data is cleaned from Docker"),
    ]

    var columns: [TTTable<CheckRow>.Column] {
        typealias C = TTTable<CheckRow>.Column
        return [
            C(id: "check", title: "", width: .fixed(TTTableCheckbox.columnWidth)) { row in
                AnyView(TTTableCheckbox(row.state, disabledReason: row.disabledReason) {})
            },
            C(id: "name", title: "Item", width: .fraction(1, min: 0)) { AnyView(Text($0.name)) },
            C(id: "size", title: "Size", width: .fixed(90), alignment: .trailing) { AnyView(Text($0.size)) },
        ]
    }

    var body: some View {
        TTTable(rows: Self.rows, columns: columns, selection: .constant("Old downloads"),
                sort: .constant(("size", true)), style: .standard, hover: .constant("Xcode caches"))
            .padding(12)
            .background(TTColor.bgCard)
    }
}

private struct ToastActionsSample: View {
    var body: some View {
        TTToast("Freed 4.2 GB · Moved 1.1 GB to Trash",
                actions: [.show {}, .emptyTrash {}, .undo {}])
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .background(TTColor.bgCard)
    }
}
