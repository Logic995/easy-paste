import Foundation

public enum ClipboardSearch {
    public static func filteredItems(
        _ items: [ClipboardItem],
        query: String,
        selector: BoardSelector,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [ClipboardItem] {
        let parsedTokens = tokens(from: query).map { $0.lowercased() }
        guard !parsedTokens.isEmpty else {
            return items.filter { matchesSelector($0, selector: selector) }
        }
        return items.filter { item in
            matchesSelector(item, selector: selector)
                && parsedTokens.allSatisfy { matchesToken($0, item: item, calendar: calendar, now: now) }
        }
    }

    public static func matchesSelector(_ item: ClipboardItem, selector: BoardSelector) -> Bool {
        switch selector {
        case .all:
            return true
        case .pinned:
            return item.pinned
        case .board(let id):
            return item.boardIDs.contains(id)
        }
    }

    private static func matchesToken(
        _ lower: String,
        item: ClipboardItem,
        calendar: Calendar,
        now: Date
    ) -> Bool {
        if lower == "pinned" {
            return item.pinned
        }

        if lower == "today" {
            return calendar.isDate(item.updatedAt, inSameDayAs: now)
        }

        if lower.hasPrefix("type:") {
            let type = String(lower.dropFirst(5))
            return item.kind.rawValue == type
        }

        if lower.hasPrefix("app:") {
            let app = String(lower.dropFirst(4))
            return item.sourceApp.lowercased().contains(app)
        }

        return searchText(for: item).contains(lower)
    }

    private static func searchText(for item: ClipboardItem) -> String {
        [
            item.title,
            item.preview,
            item.sourceApp,
            item.kind.rawValue,
            item.kind.displayName,
            item.text ?? "",
            item.imageName ?? "",
            item.ocrText ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private static func tokens(from query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false

        for character in query {
            if character == "\"" {
                inQuote.toggle()
                continue
            }

            if character.isWhitespace && !inQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
