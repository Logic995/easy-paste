import AppKit

@MainActor
enum EasyPasteIcon {
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
