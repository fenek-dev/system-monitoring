import Foundation

public enum FuzzyMatcher {
    private static let matchBonus = 1
    private static let consecutiveBonus = 6
    private static let wordStartBonus = 8

    /// nil = `query` is not a subsequence of `text`. Case- and diacritic-insensitive. Higher is better:
    /// contiguous runs and word starts score above scattered characters.
    public static func score(query: String, in text: String) -> Int? {
        let needle = foldQuery(query)
        let haystack = fold(text)
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count else { return nil }

        let bonuses = haystack.indices.map { i in
            matchBonus + (i == 0 || !haystack[i - 1].isLetter && !haystack[i - 1].isNumber ? wordStartBonus : 0)
        }
        // best[i] = top score with the current query character matched at haystack[i]; exhaustive over earlier
        // positions, so a later word-start match can beat a greedy early one.
        var best = [Int?](repeating: nil, count: haystack.count)
        for (j, wanted) in needle.enumerated() {
            var next = [Int?](repeating: nil, count: haystack.count)
            var runningMax: Int?
            for i in haystack.indices {
                if i >= 2, let earlier = best[i - 2] { runningMax = max(runningMax ?? earlier, earlier) }
                guard haystack[i] == wanted else { continue }
                var base: Int?
                if j == 0 {
                    base = 0
                } else {
                    base = runningMax
                    if i >= 1, let adjacent = best[i - 1] { base = max(base ?? Int.min, adjacent + consecutiveBonus) }
                }
                if let base { next[i] = base + bonuses[i] }
            }
            best = next
        }
        return best.compactMap { $0 }.max()
    }

    /// Empty query → `items` unchanged. Otherwise items matching in `searchText` or `sourceName`, best first,
    /// ties by `lastUsedAt` descending.
    public static func rank(_ items: [ClipItem], query: String) -> [ClipItem] {
        guard !foldQuery(query).isEmpty else { return items }
        let scored: [(item: ClipItem, score: Int)] = items.compactMap { item in
            let scores = [score(query: query, in: item.searchText), item.sourceName.flatMap { score(query: query, in: $0) }]
            guard let best = scores.compactMap({ $0 }).max() else { return nil }
            return (item, best)
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.lastUsedAt > $1.item.lastUsedAt }
            .map(\.item)
    }

    private static func fold(_ text: String) -> [Character] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }

    /// Spaces typed in the query do not have to match; word starts are rewarded instead.
    private static func foldQuery(_ query: String) -> [Character] {
        fold(query).filter { !$0.isWhitespace }
    }
}
