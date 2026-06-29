import Foundation

public final class ClipboardStore {
    public private(set) var items: [ClipboardItem] = []
    public private(set) var pinboards: [Pinboard] = []
    public private(set) var activeBoardSelector: BoardSelector = .all
    public private(set) var preferences = EasyPastePreferences()

    public let fileURL: URL
    public let limit: Int
    public var databaseURL: URL {
        SQLiteClipboardPersistence.databaseURL(forStateFile: fileURL)
    }

    public var blobsDirectoryURL: URL {
        SQLiteClipboardPersistence.blobsDirectoryURL(forStateFile: fileURL)
    }

    public init(fileURL: URL, limit: Int = 500) {
        self.fileURL = fileURL
        self.limit = limit
    }

    // MARK: - Persistence

    public func load() throws {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let state = try SQLiteClipboardPersistence.load(fromStateFile: fileURL)
            items = state.items
            pinboards = state.pinboards.sorted { $0.sortIndex < $1.sortIndex }
            activeBoardSelector = state.activeBoardSelector.selector
            preferences = state.preferences
            validateActiveBoard()
            sortAndTrim()
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = []
            pinboards = []
            activeBoardSelector = .all
            preferences = EasyPastePreferences()
            return
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(EasyPasteState.self, from: data)
        items = state.items
        pinboards = state.pinboards.sorted { $0.sortIndex < $1.sortIndex }
        activeBoardSelector = state.activeBoardSelector.selector
        preferences = state.preferences
        validateActiveBoard()
        sortAndTrim()
        do {
            try save()
            SQLiteClipboardPersistence.backupLegacyStateFileIfNeeded(fileURL)
        } catch {
            // Keep the decoded legacy state in memory if the migration cannot be
            // completed. The next launch will retry from the untouched state.json.
        }
    }

    public func save() throws {
        try Self.save(snapshot(), to: fileURL)
    }

    public func snapshot() -> EasyPasteState {
        EasyPasteState(
            items: items,
            pinboards: pinboards,
            activeBoardSelector: BoardSelectorRaw(activeBoardSelector),
            preferences: preferences
        )
    }

    public static func save(_ state: EasyPasteState, to fileURL: URL) throws {
        try SQLiteClipboardPersistence.save(state, toStateFile: fileURL)
    }

    // MARK: - Item CRUD

    public func upsert(_ item: ClipboardItem, persist: Bool = true) throws {
        if let index = items.firstIndex(where: { $0.hash == item.hash }) {
            var merged = item
            merged.id = items[index].id
            merged.createdAt = items[index].createdAt
            merged.pinned = items[index].pinned
            merged.boardIDs = items[index].boardIDs
            items.remove(at: index)
            items.insert(merged, at: 0)
        } else {
            items.insert(item, at: 0)
        }

        sortAndTrim()
        if persist {
            try save()
        }
    }

    public func updatePreferences(_ mutate: (inout EasyPastePreferences) -> Void, persist: Bool = true) throws {
        mutate(&preferences)
        sortAndTrim()
        if persist {
            try save()
        }
    }

    public func setPreferences(_ preferences: EasyPastePreferences) throws {
        self.preferences = preferences
        sortAndTrim()
        try save()
    }

    public func addIgnoredApplication(_ application: IgnoredApplication) throws {
        preferences.ignoredApplications.removeAll { $0.bundleIdentifier == application.bundleIdentifier }
        preferences.ignoredApplications.append(application)
        preferences.ignoredApplications.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        try save()
    }

    public func removeIgnoredApplication(bundleIdentifier: String) throws {
        preferences.ignoredApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        try save()
    }

    public func isIgnoredApplication(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return preferences.ignoredApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    public func togglePinned(id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        items[index].pinned.toggle()
        items[index].updatedAt = Date()
        sortAndTrim()
        try save()
    }

    public func delete(id: UUID) throws {
        items.removeAll { $0.id == id }
        try save()
    }

    public func markUsed(id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        let updatedAt = Date()
        items[index].updatedAt = updatedAt
        sortAndTrim()
        try SQLiteClipboardPersistence.saveItemUpdatedAt(
            itemID: id,
            updatedAt: updatedAt,
            toStateFile: fileURL,
            fallbackState: snapshot()
        )
    }

    public func clearUnpinned() throws {
        items.removeAll { !$0.pinned && $0.boardIDs.isEmpty }
        sortAndTrim()
        try save()
    }

    public func clearHistory() throws {
        items.removeAll()
        try save()
    }

    public func setBoards(itemID: UUID, boardIDs: Set<UUID>) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let validIDs = Set(pinboards.map(\.id))
        items[index].boardIDs = boardIDs.intersection(validIDs)
        items[index].updatedAt = Date()
        sortAndTrim()
        try save()
    }

    public func toggleBoard(itemID: UUID, boardID: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              pinboards.contains(where: { $0.id == boardID }) else {
            return
        }

        if items[index].boardIDs.contains(boardID) {
            items[index].boardIDs.remove(boardID)
        } else {
            items[index].boardIDs.insert(boardID)
        }

        items[index].updatedAt = Date()
        sortAndTrim()
        try save()
    }

    /// 异步 OCR 完成后回填识别文本，按 hash 定位条目（避免 id 在 upsert 合并时变化）。
    /// 不更新 updatedAt，避免 OCR 完成把刚拷贝的图片往前再排一次（会闪一下）。
    public func updateOCR(hash: String, ocrText: String, persist: Bool = true) throws {
        guard let index = items.firstIndex(where: { $0.hash == hash }) else {
            return
        }
        items[index].ocrText = ocrText
        if persist {
            try save()
        }
    }

    // MARK: - Pinboard CRUD

    @discardableResult
    public func createBoard(name: String) throws -> Pinboard {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? defaultBoardName() : trimmed
        let nextIndex = (pinboards.map(\.sortIndex).max() ?? -1) + 1
        let board = Pinboard(name: finalName, sortIndex: nextIndex)
        pinboards.append(board)
        try save()
        return board
    }

    public func renameBoard(id: UUID, to newName: String) throws {
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else {
            return
        }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        pinboards[index].name = trimmed
        try save()
    }

    public func deleteBoard(id: UUID) throws {
        pinboards.removeAll { $0.id == id }

        for index in items.indices where items[index].boardIDs.contains(id) {
            items[index].boardIDs.remove(id)
        }

        if case .board(let active) = activeBoardSelector, active == id {
            activeBoardSelector = .all
        }

        try save()
    }

    public func reorderBoards(_ orderedIDs: [UUID]) throws {
        var byID: [UUID: Pinboard] = [:]
        pinboards.forEach { byID[$0.id] = $0 }

        var newList: [Pinboard] = []
        for (index, id) in orderedIDs.enumerated() {
            if var board = byID.removeValue(forKey: id) {
                board.sortIndex = index
                newList.append(board)
            }
        }

        // 任何没在 orderedIDs 里的 board 追加在末尾，避免数据丢失。
        var nextIndex = newList.count
        for remaining in byID.values.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            var board = remaining
            board.sortIndex = nextIndex
            newList.append(board)
            nextIndex += 1
        }

        pinboards = newList
        try save()
    }

    // MARK: - Active board

    public func setActiveBoard(_ selector: BoardSelector) throws {
        activeBoardSelector = selector
        validateActiveBoard()
        try SQLiteClipboardPersistence.saveActiveBoardSelector(
            BoardSelectorRaw(activeBoardSelector),
            toStateFile: fileURL,
            fallbackState: snapshot()
        )
    }

    /// 列出全部可见的 board pill 顺序：[All, Pinned(有收藏时), …user boards (sortIndex 升序)]
    public var visibleBoards: [BoardSelector] {
        var result: [BoardSelector] = [.all]
        if items.contains(where: \.pinned) || activeBoardSelector == .pinned {
            result.append(.pinned)
        }
        result.append(contentsOf: pinboards.sorted { $0.sortIndex < $1.sortIndex }.map { .board($0.id) })
        return result
    }

    public func name(for selector: BoardSelector) -> String {
        switch selector {
        case .all:
            return "All"
        case .pinned:
            return "Pinned"
        case .board(let id):
            return pinboards.first { $0.id == id }?.name ?? "Pinboard"
        }
    }

    /// 当前 selector 下的 items 子集（不含搜索 query 过滤，那部分由 ClipboardSearch 负责）。
    public func items(in selector: BoardSelector) -> [ClipboardItem] {
        switch selector {
        case .all:
            return items
        case .pinned:
            return items.filter { $0.pinned }
        case .board(let id):
            return items.filter { $0.boardIDs.contains(id) }
        }
    }

    // MARK: - Internal helpers

    private func validateActiveBoard() {
        if case .board(let id) = activeBoardSelector,
           !pinboards.contains(where: { $0.id == id }) {
            activeBoardSelector = .all
        }
    }

    private func sortAndTrim() {
        if let cutoff = preferences.historyRetention.cutoffDate() {
            items.removeAll { item in
                !item.pinned && item.boardIDs.isEmpty && item.updatedAt < cutoff
            }
        }

        items.sort {
            if $0.pinned != $1.pinned {
                return $0.pinned && !$1.pinned
            }

            return $0.updatedAt > $1.updatedAt
        }

        if items.count > limit {
            // 但收藏 / 已归类到 board 的 item 永不被裁掉。
            let kept = items.prefix(limit)
            let preserved = items.dropFirst(limit).filter { $0.pinned || !$0.boardIDs.isEmpty }
            items = Array(kept) + preserved
        }
    }

    private func defaultBoardName() -> String {
        var index = pinboards.count + 1
        let existing = Set(pinboards.map(\.name))

        while existing.contains("Pinboard \(index)") {
            index += 1
        }

        return "Pinboard \(index)"
    }
}
