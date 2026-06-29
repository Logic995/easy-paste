import Foundation
import Testing

@testable import EasyPasteCore

@MainActor
private func makeStore() -> ClipboardStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return ClipboardStore(fileURL: dir.appendingPathComponent("state.json"))
}

@MainActor
private func makeItem(_ tag: String, hash: String? = nil) -> ClipboardItem {
    ClipboardItem(
        kind: .text,
        title: tag,
        preview: tag,
        sourceApp: "TestApp",
        text: tag,
        hash: hash ?? "h-\(tag)"
    )
}

@Test @MainActor func createsBoardAndPersistsThenReloads() throws {
    let store = makeStore()
    let board = try store.createBoard(name: "Work")
    #expect(store.pinboards.count == 1)
    #expect(board.name == "Work")

    let store2 = ClipboardStore(fileURL: store.fileURL)
    try store2.load()
    #expect(store2.pinboards.count == 1)
    #expect(store2.pinboards.first?.name == "Work")
}

@Test @MainActor func deleteBoardCascadesToItemBoardIDs() throws {
    let store = makeStore()
    let board = try store.createBoard(name: "Snippets")
    var item = makeItem("alpha")
    try store.upsert(item)
    item = store.items.first { $0.hash == "h-alpha" }!
    try store.toggleBoard(itemID: item.id, boardID: board.id)

    #expect(store.items.first(where: { $0.id == item.id })?.boardIDs.contains(board.id) == true)

    try store.deleteBoard(id: board.id)

    #expect(store.pinboards.isEmpty)
    #expect(store.items.first(where: { $0.id == item.id })?.boardIDs.isEmpty == true)
}

@Test @MainActor func deleteActiveBoardResetsToAll() throws {
    let store = makeStore()
    let board = try store.createBoard(name: "Drafts")
    try store.setActiveBoard(.board(board.id))
    #expect(store.activeBoardSelector == .board(board.id))
    try store.deleteBoard(id: board.id)
    #expect(store.activeBoardSelector == .all)
}

@Test @MainActor func setActiveBoardPersistsWithoutFullStoreRewrite() throws {
    let store = makeStore()
    let board = try store.createBoard(name: "Fast")
    try store.upsert(makeItem("kept"))

    try store.setActiveBoard(.board(board.id))

    let reloaded = ClipboardStore(fileURL: store.fileURL)
    try reloaded.load()
    #expect(reloaded.activeBoardSelector == .board(board.id))
    #expect(reloaded.items.map(\.hash) == ["h-kept"])
    #expect(reloaded.pinboards.map(\.id) == [board.id])
}

@Test @MainActor func itemsInSelectorScopesCorrectly() throws {
    let store = makeStore()
    let work = try store.createBoard(name: "Work")
    let _ = try store.createBoard(name: "Personal")

    try store.upsert(makeItem("a"))
    try store.upsert(makeItem("b"))
    let aID = store.items.first { $0.hash == "h-a" }!.id
    try store.toggleBoard(itemID: aID, boardID: work.id)
    try store.togglePinned(id: aID)

    #expect(store.items(in: .all).count == 2)
    #expect(store.items(in: .pinned).count == 1)
    #expect(store.items(in: .board(work.id)).count == 1)
    #expect(store.items(in: .board(work.id)).first?.id == aID)
}

@Test @MainActor func visibleBoardsShowsPinnedOnlyWhenNeeded() throws {
    let store = makeStore()
    let work = try store.createBoard(name: "Work")
    try store.upsert(makeItem("a"))

    #expect(store.visibleBoards == [.all, .board(work.id)])

    let id = store.items.first { $0.hash == "h-a" }!.id
    try store.togglePinned(id: id)
    #expect(store.visibleBoards == [.all, .pinned, .board(work.id)])
}

@Test @MainActor func renameBoardUpdatesNameAndIgnoresEmpty() throws {
    let store = makeStore()
    let board = try store.createBoard(name: "Old")
    try store.renameBoard(id: board.id, to: "")
    #expect(store.pinboards.first?.name == "Old") // 空名忽略
    try store.renameBoard(id: board.id, to: "  New  ")
    #expect(store.pinboards.first?.name == "New") // 自动 trim
}

@Test @MainActor func reorderBoardsRespectsProvidedOrder() throws {
    let store = makeStore()
    let a = try store.createBoard(name: "A")
    let b = try store.createBoard(name: "B")
    let c = try store.createBoard(name: "C")

    try store.reorderBoards([c.id, a.id, b.id])
    let names = store.pinboards.sorted { $0.sortIndex < $1.sortIndex }.map(\.name)
    #expect(names == ["C", "A", "B"])
}

@Test @MainActor func upsertPreservesPinAndBoardAssignmentOnSameHash() throws {
    let store = makeStore()
    let board = try store.createBoard(name: "Saved")

    try store.upsert(makeItem("alpha", hash: "stable"))
    let id = store.items.first!.id
    try store.toggleBoard(itemID: id, boardID: board.id)
    try store.togglePinned(id: id)

    var fresh = makeItem("alpha-v2", hash: "stable")
    fresh.updatedAt = Date().addingTimeInterval(5)
    try store.upsert(fresh)

    let merged = store.items.first { $0.hash == "stable" }!
    #expect(merged.boardIDs.contains(board.id))
    #expect(merged.pinned)
    #expect(merged.title == "alpha-v2")
}

@Test @MainActor func clearUnpinnedKeepsPinnedAndBoardedItems() throws {
    let store = makeStore()
    let board = try store.createBoard(name: "Keep")

    try store.upsert(makeItem("a"))
    try store.upsert(makeItem("b"))
    try store.upsert(makeItem("c"))

    let aID = store.items.first { $0.hash == "h-a" }!.id
    let bID = store.items.first { $0.hash == "h-b" }!.id
    try store.togglePinned(id: aID)
    try store.toggleBoard(itemID: bID, boardID: board.id)

    try store.clearUnpinned()

    #expect(store.items.contains { $0.id == aID })
    #expect(store.items.contains { $0.id == bID })
    #expect(!store.items.contains { $0.hash == "h-c" })
}
