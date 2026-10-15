import Foundation

public enum Fuzzy {
    /// Subsequence score. Higher is a tighter match. Nil means the query is not contained.
    public static func score(_ query: String, _ text: String) -> Double? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = text.lowercased()
        if q.isEmpty { return 1 }
        var qi = q.startIndex
        var score = 0.0
        var streak = 0
        var previous = -2
        for (offset, character) in t.enumerated() {
            if qi == q.endIndex { break }
            guard character == q[qi] else { continue }
            score += 8
            if offset == previous + 1 {
                streak += 1
                score += Double(streak) * 6
            } else {
                streak = 0
            }
            if offset == 0 || isBoundary(t, before: offset) {
                score += 12
            }
            previous = offset
            qi = q.index(after: qi)
        }
        if qi != q.endIndex { return nil }
        return score - Double(t.count) * 0.12
    }

    public static func rank<T>(_ query: String, _ items: [T], text: (T) -> String) -> [T] {
        items
            .compactMap { item -> (T, Double)? in
                guard let score = score(query, text(item)) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func isBoundary(_ text: String, before offset: Int) -> Bool {
        let index = text.index(text.startIndex, offsetBy: offset - 1)
        let character = text[index]
        return character == " " || character == "/" || character == "_" || character == "." || character == "-"
    }
}
