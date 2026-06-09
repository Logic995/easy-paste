import AppKit
import ApplicationServices
import ImageIO
import EasyPasteCore

@MainActor
final class ClipboardController {
    private let store: ClipboardStore
    private let onChange: () -> Void
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastSelfWriteChangeCount: Int?
    private var pendingSaveTask: Task<Void, Never>?
    private var saveGeneration = 0
    private struct OCRJob {
        let hash: String
        let data: Data
        let priorityDate: Date
        let notify: Bool
    }
    private var ocrQueue: [OCRJob] = []
    private var queuedOCRHashes: Set<String> = []
    private var ocrWorkerTask: Task<Void, Never>?
    private static var didPromptForAccessibility = false
    private static let pollingInterval: TimeInterval = 0.25
    private static let appleHTMLPasteboardType = NSPasteboard.PasteboardType("Apple HTML pasteboard type")

    var isPaused = false

    init(store: ClipboardStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        FileHandle.standardError.write(Data("[EasyPaste] clipboard polling started, interval=\(Self.pollingInterval)s, initial changeCount=\(pasteboard.changeCount)\n".utf8))
        _ = captureCurrentClipboard(force: true)

        let timer = Timer(timeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = self?.captureCurrentClipboard()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 给历史已捕获、但还没有 OCR 文本的图片补做一次（升级旧版本数据）。
        // 明显延后启动，避免应用刚打开或面板刚呼出时 TextRecognition 抢占资源。
        scheduleBackfillMissingOCR()
    }

    /// 对历史图片条目（没有 ocrText 的）异步补 OCR，限速避免一次性占满 CPU。
    private func scheduleBackfillMissingOCR() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, self.timer != nil else { return }
            self.backfillMissingOCR()
        }
    }

    private func backfillMissingOCR() {
        // 在 main actor 上提取出"原始可发送数据"（hash + base64），不再传 ClipboardItem，避免数据竞争。
        let jobs: [(String, Data, Date)] = store.items
            .filter { $0.kind == .image && ($0.ocrText ?? "").isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { item in
                if let base64 = item.imagePNGBase64 {
                    guard let data = Data(base64Encoded: base64) else { return nil }
                    return (item.hash, data, item.updatedAt)
                }
                guard let data = self.payloadData(relativePath: item.imageBlobPath) else { return nil }
                return (item.hash, data, item.updatedAt)
            }
        guard !jobs.isEmpty else { return }
        NSLog("EasyPaste OCR backfill: \(jobs.count) image(s)")
        for (hash, data, updatedAt) in jobs {
            enqueueOCR(hash: hash, data: data, priorityDate: updatedAt, notify: false)
        }
    }

    private static func pixelSize(from data: Data) -> NSSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }
        return NSSize(width: width, height: height)
    }

    func stop(save: Bool = true) {
        timer?.invalidate()
        timer = nil
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        ocrWorkerTask?.cancel()
        ocrWorkerTask = nil
        ocrQueue.removeAll()
        queuedOCRHashes.removeAll()
        if save {
            try? store.save()
        }
    }

    func copy(_ item: ClipboardItem, transform: ClipboardTransform) throws {
        try write(item, transform: transform)
    }

    func paste(_ item: ClipboardItem, transform: ClipboardTransform, targetApplication: NSRunningApplication?) throws {
        try write(item, transform: transform)

        Task { @MainActor in
            await Self.restoreTargetAndPaste(targetApplication)
        }
    }

    /// 立即同步一次剪贴板。用于面板呼出时确保看到的是最新内容。
    @discardableResult
    func syncNow() -> Bool {
        let start = EasyPasteDiagnostics.now()
        let captured = captureCurrentClipboard()
        EasyPasteDiagnostics.log("clipboard.syncNow", [
            "captured": "\(captured)",
            "ms": EasyPasteDiagnostics.elapsedMS(since: start)
        ])
        return captured
    }

    @discardableResult
    private func captureCurrentClipboard(force: Bool = false) -> Bool {
        let captureStart = EasyPasteDiagnostics.now()
        guard !isPaused else {
            lastChangeCount = pasteboard.changeCount
            EasyPasteDiagnostics.log("clipboard.capture.skipped", ["reason": "paused"])
            return false
        }

        let changeCount = pasteboard.changeCount
        if force, lastSelfWriteChangeCount == changeCount {
            lastChangeCount = changeCount
            return false
        }
        guard force || changeCount != lastChangeCount else {
            return false
        }

        FileHandle.standardError.write(Data("[EasyPaste] clipboard change detected: changeCount=\(changeCount) (was \(lastChangeCount))\n".utf8))

        let frontmost = NSWorkspace.shared.frontmostApplication
        if store.isIgnoredApplication(bundleIdentifier: frontmost?.bundleIdentifier) {
            lastChangeCount = changeCount
            EasyPasteDiagnostics.log("clipboard.capture.skipped", [
                "reason": "ignoredApp",
                "source": frontmost?.bundleIdentifier ?? frontmost?.localizedName ?? "unknown"
            ])
            return false
        }
        let sourceBundleID = frontmost?.bundleIdentifier
        let sourceAppName = frontmost?.localizedName

        let types = pasteboard.types ?? []
        logPasteboardChange(types: types, source: sourceBundleID ?? sourceAppName ?? "unknown")

        // Finder 复制图片文件时优先读取真实文件，避免把 file-url 当作普通链接。
        if let result = currentImageData(types: types, mode: .fileURLOnly) {
            lastChangeCount = changeCount
            let size = NSImage(data: result.png)?.size ?? .zero
            return capture(imageData: result.png, size: size, fileName: result.fileName, captureStart: captureStart)
        }

        if let urlText = currentURLText(types: types, includePlainString: false) {
            lastChangeCount = changeCount
            return capture(text: urlText, captureStart: captureStart)
        }

        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastChangeCount = changeCount
            if let urlText = normalizedURLText(text) {
                return capture(text: urlText)
            }
            let rtfData = pasteboard.data(forType: .rtf)
            let htmlData = pasteboard.data(forType: .html)
                ?? pasteboard.data(forType: Self.appleHTMLPasteboardType)
            if rtfData == nil,
               htmlData == nil,
               shouldSuppressShortPlainTextFollowUp(
                   text,
                   sourceBundleID: sourceBundleID,
                   sourceAppName: sourceAppName
               ) {
                NSLog("EasyPaste suppressed short follow-up text from \(sourceAppName ?? "unknown")")
                return false
            }
            return capture(
                text: text,
                rtfData: rtfData,
                htmlData: htmlData,
                captureStart: captureStart
            )
        }

        if let result = currentImageData(types: types, mode: .directImageOnly) {
            lastChangeCount = changeCount
            let size = NSImage(data: result.png)?.size ?? .zero
            return capture(imageData: result.png, size: size, fileName: result.fileName, captureStart: captureStart)
        }

        if let urlText = currentURLText(types: types, includePlainString: true) {
            lastChangeCount = changeCount
            return capture(text: urlText, captureStart: captureStart)
        }

        FileHandle.standardError.write(Data("[EasyPaste] change detected but no string/image content found\n".utf8))
        EasyPasteDiagnostics.log("clipboard.capture.skipped", [
            "reason": "noSupportedContent",
            "ms": EasyPasteDiagnostics.elapsedMS(since: captureStart)
        ])
        lastChangeCount = changeCount
        return false
    }

    private func logPasteboardChange(types: [NSPasteboard.PasteboardType], source: String) {
        guard EasyPasteDiagnostics.isEnabled else { return }
        let names = types.map(\.rawValue)
        let byteSummary = types.map { type -> String in
            let shortName = type.rawValue.replacingOccurrences(of: " ", with: "_")
            return "\(shortName):\(pasteboard.data(forType: type)?.count ?? -1)"
        }.joined(separator: ",")
        EasyPasteDiagnostics.log("clipboard.change", [
            "changeCount": "\(pasteboard.changeCount)",
            "source": source,
            "typeCount": "\(types.count)",
            "types": names.joined(separator: ","),
            "bytes": byteSummary
        ])
    }

    private func currentURLText(types: [NSPasteboard.PasteboardType], includePlainString: Bool) -> String? {
        let urlTypes: Set<NSPasteboard.PasteboardType> = [
            .URL,
            .fileURL,
            NSPasteboard.PasteboardType("public.url"),
            NSPasteboard.PasteboardType("public.file-url")
        ]
        if types.contains(where: { urlTypes.contains($0) }),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first {
            return normalizedURLText(url.absoluteString)
        }

        for type in urlTypes {
            if let value = pasteboard.string(forType: type),
               let normalized = normalizedURLText(value) {
                return normalized
            }
            if let data = pasteboard.data(forType: type),
               let value = String(data: data, encoding: .utf8),
               let normalized = normalizedURLText(value) {
                return normalized
            }
        }

        if includePlainString,
           let plainText = pasteboard.string(forType: .string),
           let normalized = normalizedURLText(plainText) {
            return normalized
        }

        return nil
    }

    private func normalizedURLText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClipboardFormatter.isURLLike(trimmed) ? trimmed : nil
    }

    private func shouldSuppressShortPlainTextFollowUp(
        _ text: String,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 120,
              !trimmed.contains("\n"),
              !trimmed.contains("\r"),
              let recent = store.items.first,
              recent.kind != .image,
              let recentText = recent.text,
              recentText.count >= max(240, trimmed.count * 3),
              Date().timeIntervalSince(recent.updatedAt) <= 45 else {
            return false
        }

        if let sourceBundleID, let recentBundleID = recent.sourceBundleID {
            guard sourceBundleID == recentBundleID else { return false }
        } else if let sourceAppName, recent.sourceApp != sourceAppName {
            return false
        }

        let normalizedRecent = recentText.replacingOccurrences(of: "\r\n", with: "\n")
        let firstLine = normalizedRecent
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed == firstLine
            || normalizedRecent.hasPrefix(trimmed + "\n")
    }

    /// 从剪贴板尝试拿到 PNG 数据。覆盖三种来源：
    /// 1. 从 Finder 拷贝图片文件（pasteboard 上有 file-url 指向 .png/.jpg 等）— 优先级最高
    /// 2. 截屏 / 直接拷贝图片对象（pasteboard 上有 public.png / public.tiff）
    /// 3. 其它能被 NSImage 解析的图片格式
    ///
    /// 注意：Finder 复制图片时 pasteboard 同时含有 file-url + 一份"通用文件图标"缩略图，
    /// 必须先读 file URL 的真实文件内容，否则会拿到那张通用 PNG 图标。
    private struct ImageCapture {
        let png: Data
        /// 当图片来自 Finder 文件 URL 时，记录文件名（带扩展名）和父目录名，用于搜索。
        let fileName: String?
    }
    private enum ImageCaptureMode {
        case fileURLOnly
        case directImageOnly
    }

    private func currentImageData(types: [NSPasteboard.PasteboardType], mode: ImageCaptureMode) -> ImageCapture? {
        // 1) 文件 URL 指向图片 → 读取磁盘文件原始内容（最高优先级，避免读到缩略图）
        let fileURLTypes: Set<NSPasteboard.PasteboardType> = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url")
        ]
        if mode == .fileURLOnly,
           types.contains(where: { fileURLTypes.contains($0) }),
           let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"]
            if let imageURL = fileURLs.first(where: { imageExts.contains($0.pathExtension.lowercased()) }),
               let data = try? Data(contentsOf: imageURL) {
                let parent = imageURL.deletingLastPathComponent().lastPathComponent
                let nameMix = "\(imageURL.lastPathComponent) \(parent)"
                // 已经是 PNG 直接用，否则交给 NSBitmapImageRep 重编码为 PNG
                if imageURL.pathExtension.lowercased() == "png" {
                    return ImageCapture(png: data, fileName: nameMix)
                }
                if let image = NSImage(data: data), let png = image.pngData() {
                    return ImageCapture(png: png, fileName: nameMix)
                }
                return ImageCapture(png: data, fileName: nameMix)
            }
        }

        guard mode == .directImageOnly else { return nil }

        let imageMarkers: Set<NSPasteboard.PasteboardType> = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic")
        ]
        guard types.contains(where: { imageMarkers.contains($0) }) else {
            return nil
        }

        // 2) 直接含图片 type → 优先用 NSBitmapImageRep 而不是 NSImage(pasteboard:)，
        //    后者在某些情形会拿到 PDF/缩略图。
        if let pngBytes = pasteboard.data(forType: .png) {
            return ImageCapture(png: pngBytes, fileName: nil)
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return ImageCapture(png: png, fileName: nil)
        }
        for jpegType in [NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let data = pasteboard.data(forType: jpegType),
               let image = NSImage(data: data),
               let png = image.pngData() {
                return ImageCapture(png: png, fileName: nil)
            }
        }

        // 3) 兜底：NSImage 自己识别（且 pasteboard 真有图片 type 时才走，避免把空数据吃下去）
        if let image = NSImage(pasteboard: pasteboard),
           let png = image.pngData() {
            return ImageCapture(png: png, fileName: nil)
        }

        return nil
    }

    @discardableResult
    private func capture(text: String, rtfData: Data? = nil, htmlData: Data? = nil, captureStart: CFAbsoluteTime? = nil) -> Bool {
        let start = captureStart ?? EasyPasteDiagnostics.now()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let kind = ClipboardFormatter.detectKind(normalized)
        let preview = ClipboardFormatter.preview(normalized, limit: 220)
        let title = titleForText(normalized)
        let richPayload = (rtfData ?? htmlData).map { Data(":rich:".utf8) + $0 } ?? Data()
        let hash = ClipboardHasher.hash(Data("text:\(normalized)".utf8) + richPayload)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let item = ClipboardItem(
            kind: kind,
            title: title,
            preview: preview,
            sourceApp: frontmost?.localizedName ?? "Clipboard",
            sourceBundleID: frontmost?.bundleIdentifier,
            text: normalized,
            rtfDataBase64: rtfData?.base64EncodedString(),
            htmlDataBase64: htmlData?.base64EncodedString(),
            rtfByteCount: rtfData?.count,
            htmlByteCount: htmlData?.count,
            hash: hash
        )

        do {
            let upsertStart = EasyPasteDiagnostics.now()
            try store.upsert(item, persist: false)
            scheduleSave()
            NSLog("EasyPaste captured text [\(kind.rawValue)] \(preview.prefix(60)) from \(item.sourceApp)")
            EasyPasteDiagnostics.log("clipboard.capture.text", [
                "kind": kind.rawValue,
                "chars": "\(normalized.count)",
                "rtfBytes": "\(rtfData?.count ?? 0)",
                "htmlBytes": "\(htmlData?.count ?? 0)",
                "source": item.sourceBundleID ?? item.sourceApp,
                "upsertMs": EasyPasteDiagnostics.elapsedMS(since: upsertStart),
                "totalMs": EasyPasteDiagnostics.elapsedMS(since: start)
            ])
            playSoundEffectIfNeeded()
            onChange()
            return true
        } catch {
            NSLog("EasyPaste failed to save clipboard text: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func capture(imageData: Data, size: NSSize, fileName: String? = nil, captureStart: CFAbsoluteTime? = nil) -> Bool {
        let start = captureStart ?? EasyPasteDiagnostics.now()
        let hash = ClipboardHasher.hash(Data("image:".utf8) + imageData)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let pixelSize = Self.pixelSize(from: imageData) ?? size
        // 标题：如果有文件名，用文件名（不带扩展名），否则用默认。
        let title: String = {
            guard let fileName,
                  let firstChunk = fileName.split(separator: " ").first else {
                return "图片剪贴板"
            }
            let url = URL(fileURLWithPath: String(firstChunk))
            let stem = url.deletingPathExtension().lastPathComponent
            return stem.isEmpty ? String(firstChunk) : stem
        }()
        let item = ClipboardItem(
            kind: .image,
            title: title,
            preview: "\(Int(pixelSize.width)) x \(Int(pixelSize.height))",
            sourceApp: frontmost?.localizedName ?? "Clipboard",
            sourceBundleID: frontmost?.bundleIdentifier,
            imagePNGBase64: imageData.base64EncodedString(),
            imageByteCount: imageData.count,
            imageName: fileName,
            hash: hash
        )

        do {
            let upsertStart = EasyPasteDiagnostics.now()
            try store.upsert(item, persist: false)
            scheduleSave()
            NSLog("EasyPaste captured image \(Int(pixelSize.width))x\(Int(pixelSize.height)) from \(item.sourceApp) name=\(fileName ?? "-")")
            EasyPasteDiagnostics.log("clipboard.capture.image", [
                "bytes": "\(imageData.count)",
                "pixels": "\(Int(pixelSize.width))x\(Int(pixelSize.height))",
                "source": item.sourceBundleID ?? item.sourceApp,
                "upsertMs": EasyPasteDiagnostics.elapsedMS(since: upsertStart),
                "totalMs": EasyPasteDiagnostics.elapsedMS(since: start)
            ])
            playSoundEffectIfNeeded()
            onChange()
            // 新图片优先进入 OCR 队列；识别工作在后台执行，不阻塞入列和面板首帧。
            enqueueOCR(hash: hash, data: imageData, priorityDate: item.updatedAt, notify: true)
            return true
        } catch {
            NSLog("EasyPaste failed to save clipboard image: \(error.localizedDescription)")
            return false
        }
    }

    private func enqueueOCR(hash: String, data: Data, priorityDate: Date, notify: Bool) {
        guard !data.isEmpty,
              !queuedOCRHashes.contains(hash),
              store.items.contains(where: { $0.hash == hash && ($0.ocrText ?? "").isEmpty }) else {
            return
        }
        queuedOCRHashes.insert(hash)
        ocrQueue.append(OCRJob(hash: hash, data: data, priorityDate: priorityDate, notify: notify))
        ocrQueue.sort {
            if $0.notify != $1.notify {
                return $0.notify && !$1.notify
            }
            return $0.priorityDate > $1.priorityDate
        }
        EasyPasteDiagnostics.log("ocr.enqueue", [
            "bytes": "\(data.count)",
            "hash": String(hash.prefix(10)),
            "notify": "\(notify)",
            "queue": "\(ocrQueue.count)"
        ])
        startOCRWorkerIfNeeded()
    }

    private func startOCRWorkerIfNeeded() {
        guard ocrWorkerTask == nil else { return }
        ocrWorkerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.ocrQueue.isEmpty else {
                    self.ocrWorkerTask = nil
                    return
                }
                let job = self.ocrQueue.removeFirst()
                self.queuedOCRHashes.remove(job.hash)
                let start = EasyPasteDiagnostics.now()
                EasyPasteDiagnostics.log("ocr.start", [
                    "bytes": "\(job.data.count)",
                    "hash": String(job.hash.prefix(10)),
                    "notify": "\(job.notify)",
                    "remaining": "\(self.ocrQueue.count)"
                ])
                let text = await ImageOCR.recognize(pngData: job.data)
                guard !Task.isCancelled else { return }
                if let text, !text.isEmpty {
                    self.applyOCR(hash: job.hash, text: text, notify: job.notify)
                    EasyPasteDiagnostics.log("ocr.done", [
                        "chars": "\(text.count)",
                        "hash": String(job.hash.prefix(10)),
                        "ms": EasyPasteDiagnostics.elapsedMS(since: start),
                        "notify": "\(job.notify)"
                    ])
                } else {
                    EasyPasteDiagnostics.log("ocr.empty", [
                        "hash": String(job.hash.prefix(10)),
                        "ms": EasyPasteDiagnostics.elapsedMS(since: start),
                        "notify": "\(job.notify)"
                    ])
                }
                try? await Task.sleep(nanoseconds: job.notify ? 150_000_000 : 1_000_000_000)
            }
        }
    }

    private func applyOCR(hash: String, text: String, notify: Bool) {
        do {
            try store.updateOCR(hash: hash, ocrText: text, persist: false)
            scheduleSave()
            NSLog("EasyPaste OCR done (\(text.count) chars)")
            if notify {
                onChange()
            }
        } catch {
            NSLog("EasyPaste OCR persist failed: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        saveGeneration += 1
        let generation = saveGeneration
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard let self else { return }
            let state = self.store.snapshot()
            let fileURL = self.store.fileURL
            DispatchQueue.global(qos: .utility).async {
                let start = EasyPasteDiagnostics.now()
                do {
                    try ClipboardStore.save(state, to: fileURL)
                    EasyPasteDiagnostics.log("store.save", [
                        "items": "\(state.items.count)",
                        "ms": EasyPasteDiagnostics.elapsedMS(since: start)
                    ])
                } catch {
                    NSLog("EasyPaste delayed save failed: \(error.localizedDescription)")
                }
            }
            guard self.saveGeneration == generation else { return }
            self.pendingSaveTask = nil
        }
    }

    private func write(_ item: ClipboardItem, transform: ClipboardTransform) throws {
        pasteboard.clearContents()

        if item.kind == .image, transform == .original,
           let data = imagePNGData(for: item),
           let image = NSImage(data: data) {
            pasteboard.writeObjects([image])
        } else if transform == .original, let text = item.text {
            if item.kind == .url {
                writeURLText(text)
            } else {
                pasteboard.setString(text, forType: .string)
            }
            if shouldWriteStoredRichPayload(for: item),
               let rtfData = rtfData(for: item) {
                pasteboard.setData(rtfData, forType: .rtf)
            }
            if shouldWriteStoredRichPayload(for: item),
               let htmlData = htmlData(for: item) {
                pasteboard.setData(htmlData, forType: .html)
                pasteboard.setData(htmlData, forType: Self.appleHTMLPasteboardType)
            }
        } else {
            let text = try ClipboardFormatter.format(item.text ?? "", as: transform)
            pasteboard.setString(text, forType: .string)
        }

        let changeCount = pasteboard.changeCount
        lastChangeCount = changeCount
        lastSelfWriteChangeCount = changeCount
    }

    private func shouldWriteStoredRichPayload(for item: ClipboardItem) -> Bool {
        guard item.kind != .url else { return false }
        let bundleID = item.sourceBundleID?.lowercased() ?? ""
        let sourceApp = item.sourceApp.lowercased()
        if bundleID == "com.cmuxterm.app" || sourceApp.contains("cmux") {
            return false
        }
        return true
    }

    private func writeURLText(_ text: String) {
        guard let normalized = normalizedURLText(text),
              ClipboardFormatter.isURLLike(normalized) else {
            pasteboard.setString(text, forType: .string)
            return
        }

        // Some apps look for URL pasteboard types instead of plain text when pasting links.
        // Keep .string for universal paste, and add the standard URL flavors for link-aware apps.
        pasteboard.setString(normalized, forType: .string)
        pasteboard.setString(normalized, forType: .URL)
        pasteboard.setString(normalized, forType: NSPasteboard.PasteboardType("public.url"))

        if let url = URL(string: normalized),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "ssh", "git"].contains(scheme) {
            pasteboard.writeObjects([url as NSURL])
            if url.isFileURL {
                pasteboard.setString(normalized, forType: .fileURL)
                pasteboard.setString(normalized, forType: NSPasteboard.PasteboardType("public.file-url"))
            }
        }
    }

    private func rtfData(for item: ClipboardItem) -> Data? {
        if let base64 = item.rtfDataBase64,
           let data = Data(base64Encoded: base64) {
            return data
        }
        return payloadData(relativePath: item.rtfBlobPath)
    }

    private func htmlData(for item: ClipboardItem) -> Data? {
        if let base64 = item.htmlDataBase64,
           let data = Data(base64Encoded: base64) {
            return data
        }
        return payloadData(relativePath: item.htmlBlobPath)
    }

    private func imagePNGData(for item: ClipboardItem) -> Data? {
        if let base64 = item.imagePNGBase64,
           let data = Data(base64Encoded: base64) {
            return data
        }
        return payloadData(relativePath: item.imageBlobPath)
    }

    private func payloadData(relativePath: String?) -> Data? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let start = EasyPasteDiagnostics.now()
        let url = store.fileURL.deletingLastPathComponent().appendingPathComponent(relativePath)
        let data = try? Data(contentsOf: url)
        EasyPasteDiagnostics.log("blob.read", [
            "bytes": "\(data?.count ?? 0)",
            "ms": EasyPasteDiagnostics.elapsedMS(since: start),
            "name": url.lastPathComponent,
            "ok": "\(data != nil)"
        ])
        return data
    }

    func playSoundEffectIfNeeded() {
        guard store.preferences.soundEffects else { return }
        if let sound = NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Pop")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func sourceApplicationName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Clipboard"
    }

    private func titleForText(_ text: String) -> String {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? text

        let title = ClipboardFormatter.preview(firstLine, limit: 72)
        return title.isEmpty ? "文本剪贴板" : title
    }

    private static func restoreTargetAndPaste(_ targetApplication: NSRunningApplication?) async {
        let target = targetApplication.flatMap { $0.isTerminated ? nil : $0 }
        if let target {
            NSApp.deactivate()
            activate(target)

            if await waitUntilFrontmost(target, timeout: 0.85) == false {
                activate(target)
                try? await Task.sleep(nanoseconds: 120_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
        } else {
            NSApp.deactivate()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        promptForAccessibilityIfNeeded()
        sendCommandV(to: target?.processIdentifier)
    }

    private static func activate(_ target: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: target)
            _ = target.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        } else {
            target.activate(options: [.activateAllWindows])
        }
    }

    private static func waitUntilFrontmost(_ target: NSRunningApplication, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                return true
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private static func promptForAccessibilityIfNeeded() {
        guard AXIsProcessTrusted() == false, didPromptForAccessibility == false else { return }
        didPromptForAccessibility = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        NSLog("EasyPaste needs Accessibility permission to send Command-V to the target app.")
    }

    private static func sendCommandV(to processIdentifier: pid_t?) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        if let processIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != processIdentifier {
            keyDown?.postToPid(processIdentifier)
            keyUp?.postToPid(processIdentifier)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
