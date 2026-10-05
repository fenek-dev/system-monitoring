import Foundation
import Testing
@testable import ClipboardCore

@Suite struct FuzzyMatcherTests {
    private func item(_ id: Int64, _ text: String, app: String? = nil, used: Double = 0) -> ClipItem {
        ClipItem(id: id, kind: .text, text: text, sourceName: app, lastUsedAt: Date(timeIntervalSince1970: used))
    }

    @Test(arguments: [("xyz", "hello"), ("ba", "ab"), ("hello!", "hello")])
    func nonSubsequenceDoesNotMatch(query: String, text: String) {
        #expect(FuzzyMatcher.score(query: query, in: text) == nil)
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(FuzzyMatcher.score(query: "cafe", in: "Un CAFÉ") != nil)
    }

    @Test func contiguousBeatsScattered() throws {
        let contiguous = try #require(FuzzyMatcher.score(query: "abc", in: "abcxx"))
        let scattered = try #require(FuzzyMatcher.score(query: "abc", in: "axbxc"))
        #expect(contiguous > scattered)
    }

    @Test func wordStartsBeatMidWord() throws {
        let starts = try #require(FuzzyMatcher.score(query: "fb", in: "foo bar"))
        let inside = try #require(FuzzyMatcher.score(query: "fb", in: "xfoobar"))
        #expect(starts > inside)
    }

    @Test func rankExcludesNonMatchesAndOrdersBestFirst() {
        let items = [item(1, "axbxc"), item(2, "nothing"), item(3, "abc")]
        #expect(FuzzyMatcher.rank(items, query: "abc").map(\.id) == [3, 1])
    }

    @Test func rankMatchesSourceAppName() {
        let items = [item(1, "unrelated", app: "Safari"), item(2, "unrelated", app: "Notes")]
        #expect(FuzzyMatcher.rank(items, query: "saf").map(\.id) == [1])
    }

    @Test func rankBreaksTiesByRecency() {
        let items = [item(1, "same", used: 1), item(2, "same", used: 9)]
        #expect(FuzzyMatcher.rank(items, query: "same").map(\.id) == [2, 1])
    }

    @Test func emptyQueryKeepsOrder() {
        let items = [item(2, "b"), item(1, "a")]
        #expect(FuzzyMatcher.rank(items, query: "  ").map(\.id) == [2, 1])
    }
}
