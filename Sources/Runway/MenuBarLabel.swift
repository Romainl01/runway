import AppKit
import RunwayCore
import SwiftUI

/// Mini horizontal gauge (14×3 pt) + mono "18%" (or "18 · 73%"), drawn as one image so the
/// font and the template tinting are exact. Template under 80 %, amber / red above.
struct MenuBarLabel: View {
    let store: UsageStore
    @AppStorage(PrefKey.menuBarMode) private var modeRaw = MenuBarMode.session.rawValue

    private var mode: MenuBarMode { MenuBarMode(rawValue: modeRaw) ?? .session }
    private let format = RunwayFormat()

    var body: some View {
        // No session open, or a window reset since the fetch, is 0 % (the snapshot decides);
        // "–" only means no data.
        let now = store.now()
        let session = store.snapshot?.sessionPercent(at: now)
        let weekly = store.snapshot?.weeklyPercent(at: now)
        let unavailable = store.state == .expired || store.state == .claudeCodeMissing || store.snapshot == nil
        let gaugeValue = mode == .weekly ? weekly : session
        let worst: Double = switch mode {
        case .session: session ?? 0
        case .weekly: weekly ?? 0
        case .both, .icon: max(session ?? 0, weekly ?? 0)
        }

        Image(nsImage: MenuBarImage.make(
            percent: unavailable ? nil : gaugeValue,
            text: text(session: session, weekly: weekly, unavailable: unavailable),
            level: unavailable ? .normal : SeverityLevel(percent: worst)))
            .accessibilityLabel(accessibilityText(session: session, weekly: weekly))
    }

    private func text(session: Double?, weekly: Double?, unavailable: Bool) -> String? {
        if unavailable { return mode == .icon ? nil : "–" }
        let session = format.compactPercent(session ?? 0), weekly = format.compactPercent(weekly ?? 0)
        switch mode {
        case .icon: return nil
        case .session: return session
        case .weekly: return weekly
        case .both: return "\(session.dropLast()) · \(weekly)"
        }
    }

    private func accessibilityText(session: Double?, weekly: Double?) -> String {
        var parts = ["Runway"]
        if let session { let p = format.percent(session); parts.append(tr("session \(p)")) }
        if let weekly { let p = format.percent(weekly); parts.append(tr("weekly \(p)")) }
        return parts.joined(separator: ", ")
    }
}

@MainActor
enum MenuBarImage {
    static let gaugeSize = NSSize(width: 14, height: 3)
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

    static func make(percent: Double?, text: String?, level: SeverityLevel) -> NSImage {
        let color: NSColor = switch level {
        case .normal: .black
        case .warning: .runwayAmber
        case .critical: .runwayRed
        }
        let attributed = text.map {
            NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: color])
        }
        let textSize = attributed?.size() ?? .zero
        let spacing: CGFloat = attributed == nil ? 0 : 5
        let height: CGFloat = 16
        let size = NSSize(width: ceil(gaugeSize.width + spacing + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            let gaugeY = (height - gaugeSize.height) / 2
            let track = NSRect(x: 0, y: gaugeY, width: gaugeSize.width, height: gaugeSize.height)
            color.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            if let percent, percent > 0 {
                var fill = track
                fill.size.width = max(gaugeSize.height, track.width * min(percent / 100, 1))
                color.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            }
            if let attributed {
                let y = (height - textSize.height) / 2
                attributed.draw(at: NSPoint(x: gaugeSize.width + spacing, y: y))
            }
            return true
        }
        image.isTemplate = level == .normal
        return image
    }

    static func dumpSamples(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples: [(String, Double?, String?, SeverityLevel)] = [
            ("session-18", 18, "18%", .normal),
            ("both-18-73", 18, "18 · 73%", .normal),
            ("session-84", 84, "84%", .warning),
            ("session-97", 97, "97%", .critical),
            ("icon", 18, nil, .normal),
            ("unavailable", nil, "–", .normal),
        ]
        for (name, percent, text, level) in samples {
            let image = make(percent: percent, text: text, level: level)
            let scale: CGFloat = 4
            let size = NSSize(width: image.size.width * scale + 16, height: image.size.height * scale + 16)
            let out = NSImage(size: size, flipped: false) { rect in
                NSColor(white: 0.93, alpha: 1).setFill()
                rect.fill()
                image.draw(in: NSRect(x: 8, y: 8, width: image.size.width * scale, height: image.size.height * scale))
                return true
            }
            if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("menubar-\(name).png"))
            }
        }
    }
}
