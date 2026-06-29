import Foundation
import SQLite3

enum SQLiteClipboardPersistence {
    static let databaseFileName = "EasyPaste.sqlite"
    static let blobsDirectoryName = "Blobs"
    private static let schemaVersion = 1

    static func databaseURL(forStateFile fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(databaseFileName)
    }

    static func blobsDirectoryURL(forStateFile fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(blobsDirectoryName, isDirectory: true)
    }

    static func load(fromStateFile fileURL: URL) throws -> EasyPasteState {
        let supportDirectory = fileURL.deletingLastPathComponent()
        let databaseURL = databaseURL(forStateFile: fileURL)
        let db = try Database(url: databaseURL)
        defer { db.close() }
        try createSchema(in: db)

        let preferences = try loadJSON(
            key: "preferences",
            from: db,
            as: EasyPastePreferences.self
        ) ?? EasyPastePreferences()
        let activeBoard = try loadJSON(
            key: "activeBoardSelector",
            from: db,
            as: BoardSelectorRaw.self
        ) ?? .all
        let pinboards = try loadPinboards(from: db)
        var items = try loadItems(from: db)
        let boardsByItemID = try loadItemBoards(from: db)
        for index in items.indices {
            items[index].boardIDs = boardsByItemID[items[index].id] ?? []
            normalizeBlobPaths(&items[index], supportDirectory: supportDirectory)
        }
        return EasyPasteState(
            schemaVersion: schemaVersion,
            items: items,
            pinboards: pinboards,
            activeBoardSelector: activeBoard,
            preferences: preferences
        )
    }

    static func save(_ state: EasyPasteState, toStateFile fileURL: URL) throws {
        let supportDirectory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let finalDatabaseURL = databaseURL(forStateFile: fileURL)
        let finalBlobsURL = blobsDirectoryURL(forStateFile: fileURL)
        let tempID = UUID().uuidString
        let tempDatabaseURL = supportDirectory.appendingPathComponent("EasyPaste.sqlite.\(tempID).tmp")

        try? FileManager.default.removeItem(at: tempDatabaseURL)
        try FileManager.default.createDirectory(at: finalBlobsURL, withIntermediateDirectories: true)

        do {
            let db = try Database(url: tempDatabaseURL)
            try createSchema(in: db)
            try db.exec("BEGIN IMMEDIATE TRANSACTION")
            try saveKV(in: db, key: "schemaVersion", value: "\(schemaVersion)")
            try saveJSON(in: db, key: "preferences", value: state.preferences)
            try saveJSON(in: db, key: "activeBoardSelector", value: state.activeBoardSelector)
            try savePinboards(state.pinboards, in: db)
            try saveItems(
                state.items,
                in: db,
                supportDirectory: supportDirectory,
                blobsDirectory: finalBlobsURL
            )
            try db.exec("COMMIT")
            db.close()
            try replace(finalDatabaseURL, with: tempDatabaseURL)
            pruneUnreferencedBlobs(in: finalBlobsURL, keeping: referencedBlobPaths(in: state.items))
            cleanupTemporaryArtifacts(in: supportDirectory)
        } catch {
            try? FileManager.default.removeItem(at: tempDatabaseURL)
            throw error
        }
    }

    static func saveActiveBoardSelector(
        _ selector: BoardSelectorRaw,
        toStateFile fileURL: URL,
        fallbackState: EasyPasteState
    ) throws {
        let databaseURL = databaseURL(forStateFile: fileURL)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            try save(fallbackState, toStateFile: fileURL)
            return
        }

        let db = try Database(url: databaseURL)
        defer { db.close() }
        try createSchema(in: db)
        try saveJSON(in: db, key: "activeBoardSelector", value: selector)
    }

    static func saveItemUpdatedAt(
        itemID: UUID,
        updatedAt: Date,
        toStateFile fileURL: URL,
        fallbackState: EasyPasteState
    ) throws {
        let databaseURL = databaseURL(forStateFile: fileURL)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            try save(fallbackState, toStateFile: fileURL)
            return
        }

        let db = try Database(url: databaseURL)
        defer { db.close() }
        try createSchema(in: db)
        let statement = try db.prepare("UPDATE items SET updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, updatedAt.timeIntervalSinceReferenceDate)
        bindText(statement, index: 2, value: itemID.uuidString)
        try db.stepDone(statement)
    }

    static func backupLegacyStateFileIfNeeded(_ fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("state.json.backup-\(stamp)")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
    }

    private static func replace(_ finalURL: URL, with tempURL: URL) throws {
        let backupURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent("\(finalURL.lastPathComponent).old-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.moveItem(at: finalURL, to: backupURL)
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            try? FileManager.default.removeItem(at: backupURL)
        } catch {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: finalURL)
            }
            throw error
        }
    }

    private static func createSchema(in db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS kv_store (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY NOT NULL,
            hash TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            preview TEXT NOT NULL,
            source_app TEXT NOT NULL,
            source_bundle_id TEXT,
            text TEXT,
            rtf_blob_path TEXT,
            html_blob_path TEXT,
            image_blob_path TEXT,
            rtf_byte_count INTEGER,
            html_byte_count INTEGER,
            image_byte_count INTEGER,
            image_name TEXT,
            ocr_text TEXT,
            pinned INTEGER NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_items_updated_at ON items(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_hash ON items(hash);
        CREATE INDEX IF NOT EXISTS idx_items_kind ON items(kind);
        CREATE INDEX IF NOT EXISTS idx_items_source_bundle ON items(source_bundle_id);
        CREATE TABLE IF NOT EXISTS pinboards (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            sort_index INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS item_boards (
            item_id TEXT NOT NULL,
            board_id TEXT NOT NULL,
            PRIMARY KEY (item_id, board_id)
        );
        """)
    }

    private static func loadJSON<T: Decodable>(key: String, from db: Database, as type: T.Type) throws -> T? {
        let statement = try db.prepare("SELECT value FROM kv_store WHERE key = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: key)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = columnText(statement, index: 0),
              let data = value.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private static func saveJSON<T: Encodable>(in db: Database, key: String, value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = []
        let data = try encoder.encode(value)
        try saveKV(in: db, key: key, value: String(decoding: data, as: UTF8.self))
    }

    private static func saveKV(in db: Database, key: String, value: String) throws {
        let statement = try db.prepare("""
        INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: key)
        bindText(statement, index: 2, value: value)
        try db.stepDone(statement)
    }

    private static func loadPinboards(from db: Database) throws -> [Pinboard] {
        let statement = try db.prepare("""
        SELECT id, name, created_at, sort_index FROM pinboards ORDER BY sort_index ASC
        """)
        defer { sqlite3_finalize(statement) }
        var result: [Pinboard] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let name = columnText(statement, index: 1) else {
                continue
            }
            result.append(Pinboard(
                id: id,
                name: name,
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                sortIndex: Int(sqlite3_column_int64(statement, 3))
            ))
        }
        return result
    }

    private static func savePinboards(_ pinboards: [Pinboard], in db: Database) throws {
        let statement = try db.prepare("""
        INSERT INTO pinboards (id, name, created_at, sort_index) VALUES (?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        for pinboard in pinboards {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bindText(statement, index: 1, value: pinboard.id.uuidString)
            bindText(statement, index: 2, value: pinboard.name)
            sqlite3_bind_double(statement, 3, pinboard.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(statement, 4, Int64(pinboard.sortIndex))
            try db.stepDone(statement)
        }
    }

    private static func loadItems(from db: Database) throws -> [ClipboardItem] {
        let statement = try db.prepare("""
        SELECT id, kind, title, preview, source_app, source_bundle_id, text,
               rtf_blob_path, html_blob_path, image_blob_path,
               rtf_byte_count, html_byte_count, image_byte_count,
               image_name, ocr_text, pinned, created_at, updated_at, hash
        FROM items
        ORDER BY pinned DESC, updated_at DESC
        """)
        defer { sqlite3_finalize(statement) }
        var result: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let kindRaw = columnText(statement, index: 1),
                  let kind = ClipboardKind(rawValue: kindRaw),
                  let title = columnText(statement, index: 2),
                  let preview = columnText(statement, index: 3),
                  let sourceApp = columnText(statement, index: 4),
                  let hash = columnText(statement, index: 18) else {
                continue
            }
            result.append(ClipboardItem(
                id: id,
                kind: kind,
                title: title,
                preview: preview,
                sourceApp: sourceApp,
                sourceBundleID: columnText(statement, index: 5),
                text: columnText(statement, index: 6),
                rtfBlobPath: columnText(statement, index: 7),
                htmlBlobPath: columnText(statement, index: 8),
                imageBlobPath: columnText(statement, index: 9),
                rtfByteCount: columnOptionalInt(statement, index: 10),
                htmlByteCount: columnOptionalInt(statement, index: 11),
                imageByteCount: columnOptionalInt(statement, index: 12),
                imageName: columnText(statement, index: 13),
                ocrText: columnText(statement, index: 14),
                pinned: sqlite3_column_int(statement, 15) != 0,
                boardIDs: [],
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 16)),
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 17)),
                hash: hash
            ))
        }
        return result
    }

    private static func loadItemBoards(from db: Database) throws -> [UUID: Set<UUID>] {
        let statement = try db.prepare("SELECT item_id, board_id FROM item_boards")
        defer { sqlite3_finalize(statement) }
        var result: [UUID: Set<UUID>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let itemText = columnText(statement, index: 0),
                  let boardText = columnText(statement, index: 1),
                  let itemID = UUID(uuidString: itemText),
                  let boardID = UUID(uuidString: boardText) else {
                continue
            }
            result[itemID, default: []].insert(boardID)
        }
        return result
    }

    private static func saveItems(
        _ items: [ClipboardItem],
        in db: Database,
        supportDirectory: URL,
        blobsDirectory: URL
    ) throws {
        let itemStatement = try db.prepare("""
        INSERT INTO items (
            id, hash, kind, title, preview, source_app, source_bundle_id, text,
            rtf_blob_path, html_blob_path, image_blob_path,
            rtf_byte_count, html_byte_count, image_byte_count,
            image_name, ocr_text, pinned, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(itemStatement) }
        let boardStatement = try db.prepare("""
        INSERT INTO item_boards (item_id, board_id) VALUES (?, ?)
        """)
        defer { sqlite3_finalize(boardStatement) }

        for item in items {
            let payload = try persistPayloads(
                for: item,
                supportDirectory: supportDirectory,
                blobsDirectory: blobsDirectory
            )
            sqlite3_reset(itemStatement)
            sqlite3_clear_bindings(itemStatement)
            bindText(itemStatement, index: 1, value: item.id.uuidString)
            bindText(itemStatement, index: 2, value: item.hash)
            bindText(itemStatement, index: 3, value: item.kind.rawValue)
            bindText(itemStatement, index: 4, value: item.title)
            bindText(itemStatement, index: 5, value: item.preview)
            bindText(itemStatement, index: 6, value: item.sourceApp)
            bindText(itemStatement, index: 7, value: item.sourceBundleID)
            bindText(itemStatement, index: 8, value: item.text)
            bindText(itemStatement, index: 9, value: payload.rtfPath)
            bindText(itemStatement, index: 10, value: payload.htmlPath)
            bindText(itemStatement, index: 11, value: payload.imagePath)
            bindInt(itemStatement, index: 12, value: payload.rtfBytes)
            bindInt(itemStatement, index: 13, value: payload.htmlBytes)
            bindInt(itemStatement, index: 14, value: payload.imageBytes)
            bindText(itemStatement, index: 15, value: item.imageName)
            bindText(itemStatement, index: 16, value: item.ocrText)
            sqlite3_bind_int(itemStatement, 17, item.pinned ? 1 : 0)
            sqlite3_bind_double(itemStatement, 18, item.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(itemStatement, 19, item.updatedAt.timeIntervalSinceReferenceDate)
            try db.stepDone(itemStatement)

            for boardID in item.boardIDs {
                sqlite3_reset(boardStatement)
                sqlite3_clear_bindings(boardStatement)
                bindText(boardStatement, index: 1, value: item.id.uuidString)
                bindText(boardStatement, index: 2, value: boardID.uuidString)
                try db.stepDone(boardStatement)
            }
        }
    }

    private struct PayloadRefs {
        var rtfPath: String?
        var htmlPath: String?
        var imagePath: String?
        var rtfBytes: Int?
        var htmlBytes: Int?
        var imageBytes: Int?
    }

    private static func persistPayloads(
        for item: ClipboardItem,
        supportDirectory: URL,
        blobsDirectory: URL
    ) throws -> PayloadRefs {
        let itemDirectory = blobsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        var refs = PayloadRefs()
        refs.rtfPath = try persistPayload(
            base64: item.rtfDataBase64,
            existingPath: item.rtfBlobPath,
            supportDirectory: supportDirectory,
            itemDirectory: itemDirectory,
            relativePath: "\(blobsDirectoryName)/\(item.id.uuidString)/content.rtf"
        )
        refs.htmlPath = try persistPayload(
            base64: item.htmlDataBase64,
            existingPath: item.htmlBlobPath,
            supportDirectory: supportDirectory,
            itemDirectory: itemDirectory,
            relativePath: "\(blobsDirectoryName)/\(item.id.uuidString)/content.html"
        )
        refs.imagePath = try persistPayload(
            base64: item.imagePNGBase64,
            existingPath: item.imageBlobPath,
            supportDirectory: supportDirectory,
            itemDirectory: itemDirectory,
            relativePath: "\(blobsDirectoryName)/\(item.id.uuidString)/image.png"
        )
        refs.rtfBytes = byteCount(base64: item.rtfDataBase64, path: refs.rtfPath, fallback: item.rtfByteCount, supportDirectory: supportDirectory)
        refs.htmlBytes = byteCount(base64: item.htmlDataBase64, path: refs.htmlPath, fallback: item.htmlByteCount, supportDirectory: supportDirectory)
        refs.imageBytes = byteCount(base64: item.imagePNGBase64, path: refs.imagePath, fallback: item.imageByteCount, supportDirectory: supportDirectory)
        return refs
    }

    private static func persistPayload(
        base64: String?,
        existingPath: String?,
        supportDirectory: URL,
        itemDirectory: URL,
        relativePath: String
    ) throws -> String? {
        let targetURL = supportDirectory.appendingPathComponent(relativePath)
        if let base64, let data = Data(base64Encoded: base64) {
            try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
            try data.write(to: targetURL, options: .atomic)
            return relativePath
        }
        guard let existingPath, !existingPath.isEmpty else { return nil }
        let sourceURL = supportDirectory.appendingPathComponent(existingPath)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return existingPath
        }
        return nil
    }

    private static func referencedBlobPaths(in items: [ClipboardItem]) -> Set<String> {
        var paths = Set<String>()
        for item in items {
            if item.rtfDataBase64 != nil {
                paths.insert("\(blobsDirectoryName)/\(item.id.uuidString)/content.rtf")
            } else if let path = item.rtfBlobPath {
                paths.insert(path)
            }

            if item.htmlDataBase64 != nil {
                paths.insert("\(blobsDirectoryName)/\(item.id.uuidString)/content.html")
            } else if let path = item.htmlBlobPath {
                paths.insert(path)
            }

            if item.imagePNGBase64 != nil {
                paths.insert("\(blobsDirectoryName)/\(item.id.uuidString)/image.png")
            } else if let path = item.imageBlobPath {
                paths.insert(path)
            }
        }
        return paths
    }

    private static func pruneUnreferencedBlobs(in blobsDirectory: URL, keeping referencedPaths: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: blobsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let basePath = blobsDirectory.resolvingSymlinksInPath().path
        var directories: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.append(url)
                continue
            }
            let filePath = url.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(basePath + "/") else { continue }
            let localPath = String(filePath.dropFirst(basePath.count + 1))
            let relativePath = "\(blobsDirectoryName)/\(localPath)"
            if !referencedPaths.contains(relativePath) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private static func cleanupTemporaryArtifacts(in supportDirectory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: supportDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in contents {
            let name = url.lastPathComponent
            let shouldRemove = (name.hasPrefix("EasyPaste.sqlite.") && (name.contains(".tmp") || name.contains(".old-")))
                || (name.hasPrefix("Blobs.") && name.hasSuffix(".tmp"))
                || name.hasPrefix("state.json.sb-")
            if shouldRemove {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func byteCount(
        base64: String?,
        path: String?,
        fallback: Int?,
        supportDirectory: URL
    ) -> Int? {
        if let base64, let data = Data(base64Encoded: base64) {
            return data.count
        }
        if let path {
            let url = supportDirectory.appendingPathComponent(path)
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]) {
                return values.fileSize
            }
        }
        return fallback
    }

    private static func normalizeBlobPaths(_ item: inout ClipboardItem, supportDirectory: URL) {
        item.rtfDataBase64 = nil
        item.htmlDataBase64 = nil
        item.imagePNGBase64 = nil
        item.rtfBlobPath = existingRelativePath(item.rtfBlobPath, supportDirectory: supportDirectory)
        item.htmlBlobPath = existingRelativePath(item.htmlBlobPath, supportDirectory: supportDirectory)
        item.imageBlobPath = existingRelativePath(item.imageBlobPath, supportDirectory: supportDirectory)
    }

    private static func existingRelativePath(_ path: String?, supportDirectory: URL) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url = supportDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? path : nil
    }

    private static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private static func bindInt(_ statement: OpaquePointer?, index: Int32, value: Int?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private static func columnOptionalInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    final class Database {
        private var handle: OpaquePointer?

        init(url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
                throw NSError(domain: "EasyPasteSQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try exec("PRAGMA journal_mode=DELETE")
            try exec("PRAGMA synchronous=NORMAL")
            try exec("PRAGMA foreign_keys=ON")
        }

        func close() {
            if let handle {
                sqlite3_close(handle)
            }
            handle = nil
        }

        func exec(_ sql: String) throws {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? lastError
                sqlite3_free(error)
                throw NSError(domain: "EasyPasteSQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        func prepare(_ sql: String) throws -> OpaquePointer? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "EasyPasteSQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: lastError])
            }
            return statement
        }

        func stepDone(_ statement: OpaquePointer?) throws {
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "EasyPasteSQLite", code: 4, userInfo: [NSLocalizedDescriptionKey: lastError])
            }
        }

        private var lastError: String {
            handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
