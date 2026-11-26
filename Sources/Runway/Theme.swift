import RunwayCore
import AppKit
import SwiftUI

/// Minimal, Vercel / Linear-like: solid surfaces, 1 px borders, colour only for problems.
/// The "Liquid glass" cheatcode swaps the neutrals for Apple's semantic colours, which stay legible
/// (and vibrant) on the system material; hex neutrals are tuned for an opaque background only.
@MainActor
enum Theme {
    private static var glass: Bool { Cheatcodes.shared.theme == .glass }

    // In glass these are hierarchical styles (.primary, .secondary…): SwiftUI renders them vibrant on the
    // system material, like a native menu. A fixed colour (hex or NSColor) sits flat on the glass and
    // loses contrast. Glass has no tertiary text: too faint over a light wallpaper.
    static var background: AnyShapeStyle { glass ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(solid.background) }
    static var surface: AnyShapeStyle { glass ? AnyShapeStyle(.quaternary) : AnyShapeStyle(solid.surface) }
    static var border: AnyShapeStyle { glass ? AnyShapeStyle(.separator) : AnyShapeStyle(solid.border) }
    static var text: AnyShapeStyle { glass ? AnyShapeStyle(.primary) : AnyShapeStyle(solid.text) }
    static var secondary: AnyShapeStyle { glass ? AnyShapeStyle(.secondary) : AnyShapeStyle(solid.secondary) }
    static var tertiary: AnyShapeStyle { glass ? AnyShapeStyle(.secondary) : AnyShapeStyle(solid.tertiary) }
    static var track: AnyShapeStyle { glass ? AnyShapeStyle(.quaternary) : AnyShapeStyle(solid.track) }
    static let clear = AnyShapeStyle(Color.clear)
    static var isGlass: Bool { glass }

    private enum solid {
        static let background = dynamic(dark: 0x0A0A0A, light: 0xFFFFFF)
        static let surface = dynamic(dark: 0x111111, light: 0xFAFAFA)
        static let border = dynamic(dark: 0x262626, light: 0xEAEAEA)
        static let text = dynamic(dark: 0xEDEDED, light: 0x171717)
        static let secondary = dynamic(dark: 0xA1A1A1, light: 0x666666)
        static let tertiary = dynamic(dark: 0x8A8A8A, light: 0x767676)
        static let track = dynamic(dark: 0x262626, light: 0xEAEAEA)
    }

    static let amber = Color(nsColor: .runwayAmber)
    static let red = Color(nsColor: .runwayRed)

    static let popoverWidth: CGFloat = 320
    static let padding: CGFloat = 16
    /// Preview window only: the real panel's shape is the system's.
    static let popoverRadius: CGFloat = 12
    static let controlRadius: CGFloat = 6
    static let pillRadius: CGFloat = 4
    static let hairline: CGFloat = 1

    /// The only motion besides the refresh icon: 150 ms ease-out.
    static let transition = Animation.easeOut(duration: 0.15)

    /// SF Mono, tabular by construction.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    nonisolated static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

enum SeverityLevel: Equatable {
    case normal, warning, critical

    init(percent: Double) {
        switch percent {
        case 95...: self = .critical
        case 80...: self = .warning
        default: self = .normal
        }
    }

    /// Gauge fill: text colour < 80 %, amber ≥ 80 %, red ≥ 95 %.
    @MainActor var fill: AnyShapeStyle {
        switch self {
        case .normal: Theme.text
        case .warning: AnyShapeStyle(Theme.amber)
        case .critical: AnyShapeStyle(Theme.red)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    /// The two alert colours, shared by the popover and the menu bar image.
    static let runwayAmber = NSColor(hex: 0xF5A524)
    static let runwayRed = NSColor(hex: 0xE5484D)

    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// 4 pt solid gauge, radius 2.
struct Gauge: View {
    var percent: Double
    var muted: Bool

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(percent / 100, 0), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                RoundedRectangle(cornerRadius: 2)
                    .fill(muted ? Theme.tertiary : SeverityLevel(percent: percent).fill)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .animation(Theme.transition, value: percent)
        .accessibilityHidden(true)
    }
}

/// 1 px separator, edge to edge.
struct Hairline: View {
    var body: some View {
        // Glass: inset like an NSMenu separator; solid: edge to edge.
        Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            .padding(.horizontal, Theme.isGlass ? 12 : 0)
    }
}

/// 24 pt icon button, no background, surface on hover.
struct IconButton: View {
    var systemImage: String
    var size: CGFloat = 12
    var help: String
    var spinning = false
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                .symbolEffect(.rotate.clockwise, options: .repeat(.continuous), isActive: spinning && !reduceMotion)
                .frame(width: 24, height: 24)
                .background(hovering ? Theme.surface : Theme.clear, in: .rect(cornerRadius: Theme.controlRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.transition, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Bordered pill (radius 4).
struct Pill: View {
    var text: String
    var foreground: AnyShapeStyle = Theme.secondary
    var background: AnyShapeStyle = Theme.clear
    var border: AnyShapeStyle = Theme.border

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: .rect(cornerRadius: Theme.pillRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.pillRadius).strokeBorder(border, lineWidth: 1))
    }
}

/// Text link, secondary, underlined on hover.
struct HoverUnderline: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .underline(hovering)
            .foregroundStyle(hovering ? Theme.text : Theme.secondary)
            .onHover { hovering = $0 }
    }
}

/// Monochrome switch: on = text colour track with background knob.
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                configuration.label
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.text : Theme.track)
                    Circle()
                        .fill(configuration.isOn ? Theme.background : Theme.secondary)
                        .padding(2)
                }
                .frame(width: 26, height: 15)
                .animation(Theme.transition, value: configuration.isOn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? tr("On") : tr("Off"))
    }
}
