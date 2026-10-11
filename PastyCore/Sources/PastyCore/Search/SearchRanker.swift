import Foundation

/// A normalized search query.
public struct SearchQuery: Sendable, Equatable {
    /// The full query, trimmed and lowercased.
    public let phrase: String
    /// Distinct whitespace-separated terms, lowercased.
    public let tokens: [String]

    /// Bounds that keep a pasted wall of text from turning into an enormous query.
    public static let maxPhraseLength = 256
    public static let maxTokens = 12

    public init(_ raw: String) {
        let phrase = String(raw.prefix(Self.maxPhraseLength * 2).trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(Self.maxPhraseLength))
        self.phrase = phrase
        var seen = Set<String>()
        tokens = Array(phrase.split(whereSeparator: \.isWhitespace).map(String.init).filter { seen.insert($0).inserted }.prefix(Self.maxTokens))
    }

    public var isEmpty: Bool { tokens.isEmpty }

    static func escapeLike(_ token: String) -> String {
        var escaped = ""
        for character in token {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}

/// Orders search candidates so the most relevant entries come first.
///
/// Scoring tiers (higher wins), with recency as the tiebreaker:
/// exact match → prefix → whole-word → substring → all terms present → found deeper in content → metadata only.
public enum SearchRanker {
    public struct Candidate: Sendable {
        public var item: ClipItem
        public var preview: String

        public init(item: ClipItem, preview: String) {
            self.item = item
            self.preview = preview
        }
    }

    public static func rank(_ candidates: [Candidate], for query: SearchQuery) -> [ClipItem] {
        guard !query.isEmpty else { return candidates.map(\.item) }
        let scored = candidates.enumerated().map { offset, candidate in
            (score: score(candidate, query: query), offset: offset, item: candidate.item)
        }
        // Candidates arrive newest-first, so the original offset is the recency tiebreaker.
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.item)
    }

    public static func score(_ candidate: Candidate, query: SearchQuery) -> Int {
        let title = candidate.item.title.lowercased()
        let text = candidate.preview.isEmpty ? title : candidate.preview.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = query.phrase

        var score: Int
        if trimmed == phrase || title == phrase {
            score = 1_000
        } else if trimmed.hasPrefix(phrase) || title.hasPrefix(phrase) {
            score = 800
        } else if containsWord(phrase, in: text) {
            score = 600
        } else if text.contains(phrase) {
            score = 450
        } else if query.tokens.allSatisfy({ text.contains($0) }) {
            score = 300 + (query.tokens.contains { containsWord($0, in: text) } ? 50 : 0)
        } else {
            let meta = [candidate.item.sourceName, candidate.item.subtitle].compactMap { $0?.lowercased() }.joined(separator: " ")
            // Matched in the full content (beyond the preview) or only in metadata.
            score = query.tokens.allSatisfy({ meta.contains($0) }) ? 100 : 200
        }
        if candidate.item.isPinned { score += 25 }
        return score
    }

    /// True when `needle` occurs in `haystack` starting at a word boundary.
    static func containsWord(_ needle: String, in haystack: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            if range.lowerBound == haystack.startIndex {
                return true
            }
            let before = haystack[haystack.index(before: range.lowerBound)]
            if !before.isLetter && !before.isNumber {
                return true
            }
            searchRange = haystack.index(after: range.lowerBound)..<haystack.endIndex
        }
        return false
    }

    /// Ranges of `text` matching any query term, merged and sorted — for highlighting.
    public static func highlightRanges(in text: String, query: SearchQuery) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        for token in query.tokens {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: token, options: .caseInsensitive, range: searchRange) {
                ranges.append(range)
                guard range.upperBound < text.endIndex else { break }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
