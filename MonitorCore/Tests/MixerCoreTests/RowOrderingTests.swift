import Testing
@testable import MixerCore

struct RowOrderingTests {
    private func row(_ id: String) -> MixerEngine.Row {
        MixerEngine.Row(
            id: id, name: id, bundleURL: nil, isPlaying: false, isRunning: true,
            setting: AppVolume(), failed: false, hidden: false, silenced: false)
    }

    @Test func noFrozenOrderKeepsEngineOrder() {
        let rows = [row("b"), row("a")]
        #expect(RowOrdering.apply(frozen: nil, to: rows).map(\.id) == ["b", "a"])
    }

    /// Rows must not move under the pointer when an app starts or stops playing.
    @Test func frozenOrderWinsOverEngineOrder() {
        let rows = [row("c"), row("a"), row("b")]
        #expect(RowOrdering.apply(frozen: ["a", "b", "c"], to: rows).map(\.id) == ["a", "b", "c"])
    }

    @Test func newRowsAppendInEngineOrder() {
        let rows = [row("new2"), row("b"), row("new1"), row("a")]
        #expect(RowOrdering.apply(frozen: ["a", "b"], to: rows).map(\.id) == ["a", "b", "new2", "new1"])
    }

    @Test func rowsThatDisappearedAreDropped() {
        #expect(RowOrdering.apply(frozen: ["a", "gone", "b"], to: [row("b"), row("a")]).map(\.id) == ["a", "b"])
    }
}
