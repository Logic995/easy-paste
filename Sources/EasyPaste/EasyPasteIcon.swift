import AppKit

@MainActor
enum EasyPasteIcon {
    /// Returns a configured SF Symbol and guarantees a visible image even when a
    /// symbol is unavailable on the current macOS release.
    static func symbol(
        named name: String,
        fallbacks: [String] = [],
        accessibilityDescription: String,
        pointSize: CGFloat,
        weight: NSFont.Weight
    ) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let candidates = [name] + fallbacks + ["square"]

        for candidate in candidates {
            guard let image = NSImage(
                systemSymbolName: candidate,
                accessibilityDescription: accessibilityDescription
            ) else {
                continue
            }
            let configured = image.withSymbolConfiguration(configuration) ?? image
            configured.accessibilityDescription = accessibilityDescription
            return configured
        }

        return fallbackGlyph(
            accessibilityDescription: accessibilityDescription,
            pointSize: pointSize
        )
    }

    static func statusBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            drawRearCardEdges()

            let frontFrame = NSRect(x: 7.5, y: 2.1, width: 7.5, height: 13.2)
            clearCard(frontFrame)
            let frontCard = NSBezierPath(
                roundedRect: frontFrame,
                xRadius: 1.65,
                yRadius: 1.65
            )
            frontCard.lineWidth = 1.5
            frontCard.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Easy Paste"
        return image
    }

    /// Last-resort vector glyph for environments where SF Symbols cannot be
    /// resolved. It follows the app icon's rounded-card language and is a
    /// template image, so the surrounding control can tint it normally.
    private static func fallbackGlyph(
        accessibilityDescription: String,
        pointSize: CGFloat
    ) -> NSImage {
        let side = max(12, ceil(pointSize * 1.25))
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth = max(1.15, pointSize * 0.09)
            let inset = lineWidth / 2 + side * 0.16
            let cardFrame = rect.insetBy(dx: inset, dy: inset)
            let card = NSBezierPath(
                roundedRect: cardFrame,
                xRadius: side * 0.14,
                yRadius: side * 0.14
            )
            card.lineWidth = lineWidth
            card.lineCapStyle = .round
            card.lineJoinStyle = .round
            NSColor.black.setStroke()
            card.stroke()

            let line = NSBezierPath()
            line.lineWidth = lineWidth
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: cardFrame.minX + side * 0.18, y: cardFrame.midY))
            line.line(to: NSPoint(x: cardFrame.maxX - side * 0.18, y: cardFrame.midY))
            line.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func drawRearCardEdges() {
        let farCard = NSBezierPath()
        farCard.lineWidth = 1.5
        farCard.lineCapStyle = .round
        farCard.lineJoinStyle = .round
        farCard.move(to: NSPoint(x: 8.1, y: 14.0))
        farCard.line(to: NSPoint(x: 4.8, y: 12.9))
        farCard.curve(
            to: NSPoint(x: 3.4, y: 10.7),
            controlPoint1: NSPoint(x: 3.8, y: 12.6),
            controlPoint2: NSPoint(x: 3.2, y: 11.7)
        )
        farCard.line(to: NSPoint(x: 5.0, y: 4.2))
        farCard.curve(
            to: NSPoint(x: 7.2, y: 2.9),
            controlPoint1: NSPoint(x: 5.2, y: 3.2),
            controlPoint2: NSPoint(x: 6.2, y: 2.6)
        )
        farCard.line(to: NSPoint(x: 8.3, y: 3.2))
        farCard.stroke()

    }

    private static func clearCard(_ frame: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.cgContext.setBlendMode(.clear)
        NSBezierPath(roundedRect: frame, xRadius: 1.65, yRadius: 1.65).fill()
        context.restoreGraphicsState()
    }

}
