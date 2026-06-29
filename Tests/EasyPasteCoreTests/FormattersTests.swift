import Foundation
import Testing

@testable import EasyPasteCore

@Test func detectsAndFormatsJSON() throws {
    let compact = #"{"name":"Easy Paste","features":["search","format"]}"#

    #expect(ClipboardFormatter.isJSON(compact))
    #expect(ClipboardFormatter.detectKind(compact) == .json)
    #expect(try ClipboardFormatter.format(compact, as: .json) == """
    {
      "name" : "Easy Paste",
      "features" : [
        "search",
        "format"
      ]
    }
    """)
}

@Test func detectsAndFormatsXML() {
    let compact = #"<root><item id="1">value</item><empty /></root>"#

    #expect(ClipboardFormatter.isXML(compact))
    #expect(ClipboardFormatter.detectKind(compact) == .xml)
    #expect(ClipboardFormatter.formatXML(compact) == """
    <root>
      <item id="1">value</item>
      <empty />
    </root>
    """)
}

@Test func detectsURLs() {
    #expect(ClipboardFormatter.detectKind("https://example.com/path?q=easy-paste#section") == .url)
    #expect(ClipboardFormatter.detectKind("http://localhost:3000") == .url)
    #expect(ClipboardFormatter.detectKind("file:///Users/luoji/Desktop/example.txt") == .url)
    #expect(ClipboardFormatter.detectKind("git@git.woa.com:YuewenGroup/ywos-solution/vega.git") == .url)
    #expect(ClipboardFormatter.detectKind("ssh://git@git.woa.com/YuewenGroup/ywos-solution/vega.git") == .url)
    #expect(ClipboardFormatter.detectKind("https://example.com/path with spaces") != .url)
}

@Test func detectsAndNormalizesMarkdown() {
    let messy = "# Title  \n\n\n- item\t\n\n```swift\nlet a = 1\n```"

    #expect(ClipboardFormatter.isMarkdown(messy))
    #expect(ClipboardFormatter.detectKind(messy) == .markdown)
    #expect(ClipboardFormatter.formatMarkdown(messy) == """
    # Title

    - item

    ```swift
    let a = 1
    ```
    """)
}

@Test func detectsSQLAndUppercasesKeywordsAndPreservesQuotedLiterals() {
    let messy = "select id, name from users where role='select' and active=1"

    #expect(ClipboardFormatter.isSQL(messy))
    #expect(ClipboardFormatter.detectKind(messy) == .sql)

    let formatted = ClipboardFormatter.formatSQL(messy)
    // 关键字大写
    #expect(formatted.contains("SELECT"))
    #expect(formatted.contains("FROM"))
    #expect(formatted.contains("WHERE"))
    #expect(formatted.contains("AND"))
    // 字符串字面量内的小写 select 被保留
    #expect(formatted.contains("'select'"))
    // 主子句换行
    #expect(formatted.contains("SELECT"))
    #expect(formatted.contains("\nFROM users"))
    #expect(formatted.contains("\nWHERE role='select'"))
    // SELECT 列表多行展开
    #expect(formatted.contains("SELECT id,\n  name"))
}

@Test func sqlDetectorRejectsProseContainingSelect() {
    // 单独散文中含 "select" 不应被识别为 SQL（缺 FROM）。
    #expect(!ClipboardFormatter.isSQL("Please select an option from the menu."))
    #expect(ClipboardFormatter.detectKind("Please select an option from the menu.") != .sql)
}

@Test func detectsYAMLAndIsIdempotent() {
    let messy = "name:\tEasy Paste\nversion :\t1.0\n\n\nfeatures:\n  - search\n  - format\n"

    #expect(ClipboardFormatter.isYAML(messy))
    #expect(ClipboardFormatter.detectKind(messy) == .yaml)

    let once = ClipboardFormatter.formatYAML(messy)
    let twice = ClipboardFormatter.formatYAML(once)
    #expect(once == twice) // 幂等
    // tab 被展开
    #expect(!once.contains("\t"))
    // key: value 单空格
    #expect(once.contains("name: Easy Paste"))
    #expect(once.contains("version: 1.0"))
    // 列表保留
    #expect(once.contains("- search"))
}

@Test func formatTransformDispatchesYAMLAndSQL() throws {
    let yaml = "key:\tvalue\n  nested: 1"
    let result = try ClipboardFormatter.format(yaml, as: .yaml)
    #expect(result.contains("key: value"))

    let sql = "select 1"
    let sqlOut = try ClipboardFormatter.format(sql, as: .sql)
    #expect(sqlOut.contains("SELECT"))
}

@Test func searchSupportsTypeAppPinnedAndDateTokens() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let calendar = Calendar(identifier: .gregorian)
    let item = ClipboardItem(
        kind: .json,
        title: "Config",
        preview: #"{"enabled":true}"#,
        sourceApp: "Safari",
        text: #"{"enabled":true}"#,
        pinned: true,
        createdAt: now,
        updatedAt: now,
        hash: "hash"
    )

    let matches = ClipboardSearch.filteredItems(
        [item],
        query: "type:json app:safari pinned today enabled",
        selector: .all,
        calendar: calendar,
        now: now
    )

    #expect(matches == [item])
}

@Test func storeUpsertKeepsPinnedItemAndMovesItToFront() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ClipboardStore(fileURL: directory.appendingPathComponent("state.json"))

    var original = ClipboardItem(
        kind: .text,
        title: "Old",
        preview: "Old",
        sourceApp: "Notes",
        text: "hello",
        pinned: false,
        hash: "same"
    )

    try store.upsert(original)
    try store.togglePinned(id: store.items[0].id)
    original.title = "New"
    original.updatedAt = Date().addingTimeInterval(10)
    try store.upsert(original)

    #expect(store.items.count == 1)
    #expect(store.items[0].title == "New")
    #expect(store.items[0].pinned)
}

@Test func markUsedMovesOriginalItemToFrontWithoutDuplicating() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ClipboardStore(fileURL: directory.appendingPathComponent("state.json"))

    let first = ClipboardItem(
        kind: .text,
        title: "First",
        preview: "First",
        sourceApp: "Notes",
        text: "first",
        updatedAt: Date().addingTimeInterval(-20),
        hash: "first"
    )
    let originalID = first.id
    let second = ClipboardItem(
        kind: .text,
        title: "Second",
        preview: "Second",
        sourceApp: "Notes",
        text: "second",
        updatedAt: Date().addingTimeInterval(-10),
        hash: "second"
    )

    try store.upsert(first)
    try store.upsert(second)
    try store.markUsed(id: originalID)

    #expect(store.items.count == 2)
    #expect(store.items[0].id == originalID)
    #expect(store.items[0].title == "First")

    let reloaded = ClipboardStore(fileURL: store.fileURL)
    try reloaded.load()
    #expect(reloaded.items.count == 2)
    #expect(reloaded.items[0].id == originalID)
}
