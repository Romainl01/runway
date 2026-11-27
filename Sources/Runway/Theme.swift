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

    static let green = Color(nsColor: .runwayGreen)
    static let amber = Color(nsColor: .runwayAmber)
    static let red = Color(nsColor: .runwayRed)

    static let popoverWidth: CGFloat = 320
    static let padding: CGFloat = 16
    /// Preview window only: the real panel's shape is the system's.
    static let popoverRadius: CGFloat = 12
    static let controlRadius: CGFloat = 6
    static let pillRadius: CGFloat = 4
    /// A highlighted list row (memory rows on hover): rounder and roomier than a control, so the highlight
    /// does not hug the text. Inset 10 × 8 inside it, pulled out by the same 10 so the text stays aligned.
    static let rowRadius: CGFloat = 8
    static let rowInset = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    static let hairline: CGFloat = 1

    /// Two text roles in a settings group, kept apart by colour and weight, not just size: the header
    /// names the group (11 pt medium, tertiary), the rows are what you act on (12 pt, text).
    static let sectionHeaderFont = Font.system(size: 11, weight: .medium)
    static let rowFont = Font.system(size: 12)

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

    /// Gauge fill: green < 80 %, amber ≥ 80 %, red ≥ 95 %.
    @MainActor var fill: AnyShapeStyle {
        switch self {
        case .normal: AnyShapeStyle(Theme.green)
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
    /// Gauge colours, shared by the popover and the menu bar image. Green is #30A46C: 3.2:1 on the light
    /// background, 6.2:1 on the dark one (graphics need 3:1), so one value serves both appearances.
    static let runwayGreen = NSColor(hex: 0x30A46C)
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
    /// Overrides the severity colour (the memory gauge follows the system's pressure, not the percentage).
    var fill: AnyShapeStyle?

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(percent / 100, 0), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                RoundedRectangle(cornerRadius: 2)
                    .fill(muted ? Theme.tertiary : (fill ?? SeverityLevel(percent: percent).fill))
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
/// Its label shows in a dark bubble under it on hover (a `.help` tooltip takes a second and is easy to miss).
/// `tooltipEdge` is the side the bubble lines up with: `.trailing` for a button at the right edge of the panel,
/// `.leading` at the left edge, so the bubble never runs out of the window. The row holding it needs `.zIndex(1)`
/// or the views below draw over the bubble.
struct IconButton: View {
    var systemImage: String
    var size: CGFloat = 12
    var help: String
    var spinning = false
    var tooltipEdge: HorizontalAlignment = .trailing
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
        .tooltip(help, edge: tooltipEdge)
        .accessibilityLabel(help)
    }
}

extension View {
    func tooltip(_ text: String, edge: HorizontalAlignment = .trailing) -> some View {
        modifier(Tooltip(text: text, edge: edge))
    }
}

/// The first bubble waits a beat, so sweeping the pointer across a row of icons doesn't flash them all;
/// once one is up, moving to its neighbour shows the next one at once, without animation.
private struct Tooltip: ViewModifier {
    let text: String
    let edge: HorizontalAlignment

    @MainActor private static var lastHidden = Date.distantPast
    private static let delay: Duration = .milliseconds(350)
    private static let warmWindow: TimeInterval = 0.5

    @State private var shown = false
    @State private var animated = true
    @State private var pending: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { inside in inside ? show() : hide() }
            // A zero-height anchor on the bottom edge, the bubble hanging from it: overlays don't take layout space.
            .overlay(alignment: .bottom) {
                Color.clear.frame(height: 0)
                    .overlay(alignment: Alignment(horizontal: edge, vertical: .top)) {
                        if shown {
                            bubble
                                .padding(.top, 6)
                                .transition(.asymmetric(insertion: insertion, removal: .identity))
                        }
                    }
            }
            .onDisappear { pending?.cancel() }
    }

    /// Grows out of the button's corner; Reduce Motion keeps the fade only. Leaving is instant, so sliding to
    /// a neighbour never shows two bubbles at once.
    private var insertion: AnyTransition {
        guard animated else { return .identity }
        if reduceMotion { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.96, anchor: UnitPoint(x: edge == .leading ? 0 : 1, y: 0)))
    }

    private var bubble: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.9), in: .rect(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(.white.opacity(0.12), lineWidth: Theme.hairline))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func show() {
        pending?.cancel()
        if Date.now.timeIntervalSince(Self.lastHidden) < Self.warmWindow {
            animated = false
            shown = true
            return
        }
        pending = Task { @MainActor in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            animated = true
            withAnimation(Theme.transition) { shown = true }
        }
    }

    private func hide() {
        pending?.cancel()
        guard shown else { return }
        Self.lastHidden = .now
        shown = false
    }
}

/// Names a group of rows ("Notifications", "Runway 0.1.0"). Rows under it use `Theme.rowFont` in `Theme.text`.
struct SectionHeader: View {
    var title: Text

    var body: some View {
        title
            .font(Theme.sectionHeaderFont)
            .foregroundStyle(Theme.tertiary)
            .accessibilityAddTraits(.isHeader)
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
                    .font(Theme.rowFont)
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

/// Small bordered button (22 pt, radius 6): "Stop", "Cancel", "Force stop". `solid` is the confirming one;
/// `destructive` is every stop ("Stop", its confirmation, "Force stop"): red text and outline, never filled;
/// `fill` stretches it to the row's width ("Check for Updates…").
struct SmallButtonStyle: ButtonStyle {
    var solid = false
    var destructive = false
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        SmallButtonBody(configuration: configuration, solid: solid, destructive: destructive, fill: fill)
    }

    private struct SmallButtonBody: View {
        let configuration: Configuration
        let solid: Bool
        let destructive: Bool
        let fill: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, 8)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: 22)
                .background(background, in: .rect(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(stroke, lineWidth: 1))
                .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.5))
                .contentShape(.rect)
                .onHover { hovering = $0 && isEnabled }
                .fixedSize(horizontal: !fill, vertical: true)
        }

        private var foreground: AnyShapeStyle {
            if destructive { return AnyShapeStyle(Theme.red) }
            return solid ? Theme.background : Theme.text
        }

        private var background: AnyShapeStyle {
            if destructive { return hovering ? AnyShapeStyle(Theme.red.opacity(0.12)) : Theme.clear }
            if solid { return Theme.text }
            return hovering ? Theme.surface : Theme.clear
        }

        private var stroke: AnyShapeStyle {
            if destructive { return AnyShapeStyle(Theme.red.opacity(0.6)) }
            return solid ? Theme.text : Theme.border
        }
    }
}

/// The one moving thing besides the refresh icon: a highlight sweeping across the text of a row being
/// stopped (design.md §5). 1.4 s linear; plain secondary text under Reduce Motion. Nowhere else.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.foregroundStyle(Theme.secondary)
        } else {
            content
                .foregroundStyle(Theme.tertiary)
                .overlay {
                    TimelineView(.animation) { context in
                        GeometryReader { geo in
                            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            let band = max(geo.size.width * 0.6, 24)
                            LinearGradient(colors: [.clear, Color(nsColor: .labelColor), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + (geo.size.width + band) * phase)
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
        }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}
