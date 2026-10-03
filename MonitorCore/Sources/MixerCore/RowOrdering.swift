public enum RowOrdering {
    /// Keeps rows in the order they had when the pointer entered the list, so a row does not move
    /// under the cursor when an app starts or stops playing. Rows that appeared since go last.
    public static func apply(frozen: [String]?, to rows: [MixerEngine.Row]) -> [MixerEngine.Row] {
        guard let frozen else { return rows }
        let position = Dictionary(frozen.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.enumerated()
            .sorted { first, second in
                switch (position[first.element.id], position[second.element.id]) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return first.offset < second.offset
                }
            }
            .map(\.element)
    }
}
