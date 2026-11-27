import AppKit

/// Runway's logo: a flat plane seen from above, nose up-right. The app icon's outline: `build-app.sh` runs
/// `make-icon.swift` with this file in front. The menu bar keeps its gauge.
enum PlaneGlyph {
    /// Nose pointing up, in a 100 × 100 box, SVG coordinates (y down), absolute M / L / C / Z only.
    static let pathData = """
        M50 4.5 C54.8 4.5 57.5 10.5 57.5 20 L57.5 35.5 L90.5 57.5 C93.6 59.4 94.5 62.5 93.2 65 \
        C92.6 66.2 91.4 66.6 90 66.2 L57.5 55.5 L57.5 73.5 L69.5 83.3 C71.2 84.5 71.6 86.8 70.6 88.4 \
        C70.1 89.2 69.2 89.5 68.3 89.2 L56.6 85.8 C56 90.8 53.4 93.8 50 93.8 C46.6 93.8 44 90.8 43.4 85.8 \
        L31.7 89.2 C30.8 89.5 29.9 89.2 29.4 88.4 C28.4 86.8 28.8 84.5 30.5 83.3 L42.5 73.5 L42.5 55.5 \
        L10 66.2 C8.6 66.6 7.4 66.2 6.8 65 C5.5 62.5 6.4 59.4 9.5 57.5 L42.5 35.5 L42.5 20 \
        C42.5 10.5 45.2 4.5 50 4.5 Z
        """

    /// The plane turned 45° clockwise (nose up-right), scaled to fit `rect` and centred on it.
    static func path(in rect: NSRect) -> NSBezierPath {
        let path = parse(pathData)
        var turn = AffineTransform(translationByX: -50, byY: -50)
        turn.append(AffineTransform(rotationByDegrees: -45))   // y-up space: negative is clockwise
        path.transform(using: turn)

        let bounds = path.bounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var fit = AffineTransform(translationByX: -bounds.midX, byY: -bounds.midY)
        fit.append(AffineTransform(scaleByX: scale, byY: scale))
        fit.append(AffineTransform(translationByX: rect.midX, byY: rect.midY))
        path.transform(using: fit)
        return path
    }

    /// Reads `pathData` into a y-up path (y is flipped so the drawing keeps its orientation).
    private static func parse(_ data: String) -> NSBezierPath {
        let path = NSBezierPath()
        var command: Character = "M"
        var numbers: [CGFloat] = []

        func point(_ i: Int) -> NSPoint { NSPoint(x: numbers[i], y: 100 - numbers[i + 1]) }
        func flush() {
            switch command {
            case "M": path.move(to: point(0))
            case "L": path.line(to: point(0))
            case "C": path.curve(to: point(4), controlPoint1: point(0), controlPoint2: point(2))
            default: break
            }
            numbers.removeAll()
        }

        for token in data.split(whereSeparator: \.isWhitespace) {
            var token = Substring(token)
            if let first = token.first, first.isLetter {
                if !numbers.isEmpty { flush() }
                command = first
                token = token.dropFirst()
                if command == "Z" { path.close(); continue }
            }
            if let value = Double(token) { numbers.append(CGFloat(value)) }
        }
        if !numbers.isEmpty { flush() }
        return path
    }
}
