import AppKit
import RunwayCore
import SwiftUI

/// Mini horizontal gauge (14×3 pt) + mono "18%" (or "18 · 73%") + " · 26 GB", drawn as one image so the
/// font and the tinting are exact. Template while usage and memory pressure are both normal; amber / red
/// otherwise, and then the normal parts use the dynamic label colour.
struct MenuBarLabel: View {
    let store: UsageStore
    let ram: RAMStore
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
            level: unavailable ? .normal : SeverityLevel(percent: worst),
            memory: ram.snapshot.map {
                MenuBarImage.Memory(text: format.wholeGigabytes($0.usedBytes), level: $0.pressure.level)
            }))
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
        if let used = ram.snapshot?.usedBytes { let m = format.wholeGigabytes(used); parts.append(tr("memory \(m)")) }
        return parts.joined(separator: ", ")
    }
}

@MainActor
enum MenuBarImage {
    static let gaugeSize = NSSize(width: 14, height: 3)
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

    struct Memory {
        var text: String
        var level: SeverityLevel
    }

    private static func color(_ level: SeverityLevel, normal: NSColor) -> NSColor {
        switch level {
        case .normal: normal
        case .warning: .runwayAmber
        case .critical: .runwayRed
        }
    }

    /// Template (the system tints it) only when nothing is amber or red. Otherwise the image is drawn in
    /// colour, and the normal parts use `labelColor`, resolved when the image is drawn so they follow the
    /// light or dark menu bar.
    static func make(percent: Double?, text: String?, level: SeverityLevel, memory: Memory? = nil) -> NSImage {
        let isTemplate = level == .normal && (memory?.level ?? .normal) == .normal
        let normal: NSColor = isTemplate ? .black : .labelColor
        let usageColor = color(level, normal: normal)
        let memoryColor = color(memory?.level ?? .normal, normal: normal)

        // Built again at every draw: a dynamic colour with an alpha is resolved when it is made, so the
        // dimmed "·" must be made while the menu bar's appearance is current.
        func makeText() -> NSAttributedString {
            let attributed = NSMutableAttributedString()
            if let text {
                attributed.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: usageColor]))
            }
            if let memory {
                if text != nil {
                    attributed.append(NSAttributedString(string: " · ", attributes: [
                        .font: font, .foregroundColor: normal.withAlphaComponent(0.5)]))
                }
                attributed.append(NSAttributedString(string: memory.text, attributes: [.font: font, .foregroundColor: memoryColor]))
            }
            return attributed
        }
        let attributed = makeText()
        let hasText = attributed.length > 0
        let textSize = attributed.size()
        let spacing: CGFloat = hasText ? 5 : 0
        let height: CGFloat = 16
        let size = NSSize(width: ceil(gaugeSize.width + spacing + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            let gaugeY = (height - gaugeSize.height) / 2
            let track = NSRect(x: 0, y: gaugeY, width: gaugeSize.width, height: gaugeSize.height)
            usageColor.withAlphaComponent(isTemplate ? 0.3 : 0.35).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            if let percent, percent > 0 {
                var fill = track
                fill.size.width = max(gaugeSize.height, track.width * min(percent / 100, 1))
                usageColor.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            }
            if hasText {
                let y = (height - textSize.height) / 2
                makeText().draw(at: NSPoint(x: gaugeSize.width + spacing, y: y))
            }
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    /// QA: samples on a light and a dark menu bar (template images are tinted the way the system would).
    static func dumpSamples(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let normal = Memory(text: "14 GB", level: .normal)
        let medium = Memory(text: "26 GB", level: .warning)
        let critical = Memory(text: "31 GB", level: .critical)
        let samples: [(String, Double?, String?, SeverityLevel, Memory?)] = [
            ("session-18", 18, "18%", .normal, nil),
            ("both-18-73", 18, "18 · 73%", .normal, nil),
            ("session-84", 84, "84%", .warning, nil),
            ("session-97", 97, "97%", .critical, nil),
            ("icon", 18, nil, .normal, nil),
            ("unavailable", nil, "–", .normal, nil),
            ("mem-normal", 14, "14%", .normal, normal),
            ("mem-medium", 14, "14%", .normal, medium),
            ("mem-critical", 14, "14%", .normal, critical),
            ("mem-usage-warning-pressure-normal", 84, "84%", .warning, normal),
            ("mem-usage-critical-pressure-medium", 97, "97%", .critical, medium),
            ("mem-icon", 18, nil, .normal, medium),
            ("mem-unavailable", nil, "–", .normal, normal),
        ]
        for (name, percent, text, level, memory) in samples {
            let image = make(percent: percent, text: text, level: level, memory: memory)
            for (suffix, dark) in [("light", false), ("dark", true)] {
                let scale: CGFloat = 4
                let size = NSSize(width: image.size.width * scale + 16, height: image.size.height * scale + 16)
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let out = NSImage(size: size, flipped: false) { rect in
                    appearance.performAsCurrentDrawingAppearance {
                        (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                        rect.fill()
                        let target = NSRect(x: 8, y: 8, width: image.size.width * scale, height: image.size.height * scale)
                        if image.isTemplate {
                            let tinted = NSImage(size: target.size, flipped: false) { r in
                                image.draw(in: r)
                                (dark ? NSColor.white : NSColor.black).setFill()
                                r.fill(using: .sourceIn)
                                return true
                            }
                            tinted.draw(in: target)
                        } else {
                            image.draw(in: target)
                        }
                    }
                    return true
                }
                if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("menubar-\(name)-\(suffix).png"))
                }
            }
        }
    }
}
