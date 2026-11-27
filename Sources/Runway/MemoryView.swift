import AppKit
import RunwayCore
import SwiftUI

extension MemoryPressure {
    @MainActor var fill: AnyShapeStyle {
        switch self {
        case .normal: AnyShapeStyle(Theme.green)
        case .warning: AnyShapeStyle(Theme.amber)
        case .critical: AnyShapeStyle(Theme.red)
        }
    }

    @MainActor var color: Color {
        switch self {
        case .normal: Theme.green
        case .warning: Theme.amber
        case .critical: Theme.red
        }
    }

    var label: String {
        switch self {
        case .normal: tr("Normal pressure")
        case .warning: tr("Medium pressure")
        case .critical: tr("Critical pressure")
        }
    }

    /// The menu bar's colour language (normal = same as the usage text).
    var level: SeverityLevel {
        switch self {
        case .normal: .normal
        case .warning: .warning
        case .critical: .critical
        }
    }
}

extension MemoryGroupKind {
    var title: String {
        switch self {
        case .simulators: tr("Simulators")
        case .servers: tr("Local servers")
        case .claude: tr("Claude Code")
        case .apps: tr("Apps")
        }
    }
}

/// The Memory tab's body (the header and the tab control belong to `UsageView`): gauge, groups, footer.
struct MemoryView: View {
    let ram: RAMStore

    private let format = RunwayFormat()
    /// A list taller than this scrolls, the rest of the popover stays put.
    private static let maxListHeight: CGFloat = 560

    @State private var confirmingID: String?
    /// A ScrollView has no height of its own: in the MenuBarExtra panel it collapsed to 0. It takes
    /// its content's height, up to the cap.
    @State private var listHeight: CGFloat = 0
    @Bindable private var cheats = Cheatcodes.shared

    var body: some View {
        let snapshot = ram.snapshot
        VStack(alignment: .leading, spacing: 0) {
            gauge(snapshot)
                .padding(Theme.padding)
            Hairline()
            ScrollView {
                Group {
                    if let snapshot { groups(snapshot) } else { skeleton }
                }
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .frame(height: min(listHeight, Self.maxListHeight))
            .overlay(alignment: .bottom) {
                if let toast = ram.toast {
                    StopToastView(toast: toast)
                        .padding(.horizontal, Theme.padding)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(Theme.transition, value: ram.toast)
            Hairline()
            PopoverFooter {
                Button("Activity Monitor ↗") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }
        }
    }

    // MARK: Gauge

    /// RAM, then swap: the rows count both, so the swap gauge is what makes them add up.
    private func gauge(_ snapshot: MemorySnapshot?) -> some View {
        let total = snapshot?.totalBytes ?? ProcessInfo.processInfo.physicalMemory
        let totalText = format.totalGigabytes(total)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                valueRow(label: tr("RAM"),
                         info: tr("Memory in use right now, out of \(totalText). macOS keeps it nearly full on purpose. The pressure tells whether it is struggling."),
                         value: snapshot.map { format.gigabytesNumber($0.usedBytes) } ?? "–",
                         suffix: " / " + totalText)
                Gauge(percent: (snapshot?.usedFraction ?? 0) * 100, muted: false, fill: snapshot?.pressure.fill)
                Group {
                    if let snapshot {
                        Text(snapshot.pressure.label)
                            .foregroundStyle(snapshot.pressure == .critical ? AnyShapeStyle(Theme.red) : Theme.tertiary)
                    } else {
                        Text("Scanning processes…").foregroundStyle(Theme.tertiary)
                    }
                }
                .font(.system(size: 11))
            }
            .accessibilityElement(children: .combine)

            if let snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    valueRow(label: tr("Swap (on disk)"),
                             info: tr("What no longer fits in RAM waits on the disk. The more there is, the slower the Mac gets when you go back to an app. The rows below count their share in RAM and on disk."),
                             value: format.bytes(snapshot.swapUsedBytes), suffix: nil)
                    Gauge(percent: min(Double(snapshot.swapUsedBytes) / Double(max(total, 1)), 1) * 100, muted: false,
                          fill: AnyShapeStyle(snapshot.pressure.color.opacity(0.6)))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func valueRow(label: String, info: String, value: String, suffix: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                InfoBubble(text: info)
            }
            Spacer()
            HStack(spacing: 0) {
                Text(verbatim: value).foregroundStyle(Theme.text)
                if let suffix { Text(verbatim: suffix).foregroundStyle(Theme.tertiary) }
            }
            .font(Theme.mono(13))
            .lineLimit(1)
            .fixedSize()
        }
    }

    // MARK: Groups

    private func groups(_ snapshot: MemorySnapshot) -> some View {
        let now = ram.now()
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(ram.groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.kind.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.bottom, 4)
                    ForEach(group.items) { item in
                        MemoryRow(item: item, state: ram.stopState(for: item.id), now: now,
                                  isConfirming: confirmingID == item.id || cheats.memoryConfirmID == item.id,
                                  forcedHover: cheats.memoryHoverID == item.id,
                                  onAskStop: { confirmingID = item.id },
                                  onCancel: { confirmingID = nil; cheats.memoryConfirmID = nil },
                                  onConfirm: {
                                      confirmingID = nil
                                      cheats.memoryConfirmID = nil
                                      ram.stop(item)
                                  },
                                  onForceStop: { ram.forceStop(item) })
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Static bars (no shimmer: it belongs to a stop in progress, nowhere else).
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            skeletonGroup(.simulators, [(96, 150)])
            skeletonGroup(.servers, [(64, 120), (52, 100)])
            skeletonGroup(.claude, [(170, 80)])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func skeletonGroup(_ kind: MemoryGroupKind, _ rows: [(CGFloat, CGFloat)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        bar(width: row.0, height: 8)
                        Spacer(minLength: 0)
                        bar(width: 40, height: 8)
                    }
                    .frame(height: 16)
                    bar(width: row.1, height: 6).frame(height: 14)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Theme.track).frame(width: width, height: height)
    }
}

// MARK: - Row

/// Name + value, then context · reason (a second line of it if too long). Hover swaps the value for "Stop" (the row keeps
/// its height); Stop asks inside the row; a stop in progress shimmers its second line.
/// "✓ wander stopped · 874 MB freed", floating over the bottom of the list for 3 s after a stop.
/// An ⓘ that shows its text in a popover as soon as the pointer is on it (a `.help` tooltip takes
/// a second to appear and is easy to miss).
private struct InfoBubble: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(shown ? Theme.text : Theme.tertiary)
            .frame(width: 16, height: 16)
            .contentShape(.rect)
            .onHover { shown = $0 }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(12)
            }
            .accessibilityLabel(text)
    }
}

private struct StopToastView: View {
    let toast: StopToast
    private let format = RunwayFormat()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.black, Theme.green)
            Text(tr("\(toast.name) stopped"))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(tr("· \(format.bytes(toast.freedBytes)) freed"))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Green tint over an opaque base: a surface-coloured card read as one more row.
        .background {
            RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.background)
            RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.green.opacity(0.14))
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.green.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct MemoryRow: View {
    let item: MemoryItem
    let state: StopState?
    let now: Date
    let isConfirming: Bool
    let forcedHover: Bool
    var onAskStop: () -> Void
    var onCancel: () -> Void
    var onConfirm: () -> Void
    var onForceStop: () -> Void

    @State private var hovering = false
    private let format = RunwayFormat()

    private var isDone: Bool {
        switch state {
        case .stopping, .stopped: true
        default: false
        }
    }

    private var isNotResponding: Bool { state == .notResponding }
    private var showsStop: Bool { (hovering || forcedHover) && state == nil && !isConfirming && item.target != nil }
    private var highlighted: Bool { hovering || forcedHover || isConfirming }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(item.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isDone ? Theme.tertiary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(format.bytes(item.bytes))
                    .font(Theme.mono(13))
                    .foregroundStyle(isDone ? Theme.tertiary : Theme.text)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(showsStop || isNotResponding || isStopped ? 0 : 1)
            }
            .frame(height: 16)
            detailLine
                .frame(minHeight: 14)
            if isConfirming { confirmation }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(highlighted ? Theme.surface : Theme.clear, in: .rect(cornerRadius: Theme.controlRadius))
        .overlay(alignment: .trailing) {
            if showsStop {
                Button("Stop", action: onAskStop)
                    .buttonStyle(SmallButtonStyle(destructive: true))
                    .padding(.trailing, 8)
            } else if isNotResponding {
                Button("Force stop", action: onForceStop)
                    .buttonStyle(SmallButtonStyle(destructive: true))
                    .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, -8)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .accessibilityAction(named: Text("Stop"), onAskStop)
    }

    private var isStopped: Bool {
        if case .stopped = state { true } else { false }
    }

    // MARK: Second line

    @ViewBuilder
    private var detailLine: some View {
        switch state {
        case .stopping:
            Text("Stopping…")
                .font(.system(size: 11))
                .lineLimit(1)
                .shimmer()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .stopped(let freed):
            let amount = format.bytes(freed)
            Text(tr("Stopped · \(amount) freed"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .notResponding, nil:
            let hasReason = item.reason != nil
            // A long reason wraps to a second line instead of being cut; the dot stays on the first one.
            HStack(alignment: .top, spacing: 6) {
                if isNotResponding {
                    Circle().fill(Theme.red).frame(width: 6, height: 6).padding(.top, 4)
                } else if hasReason {
                    Circle().fill(Theme.amber).frame(width: 6, height: 6).padding(.top, 4)
                }
                detailText
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ":8081" in mono, then the context, then the reason. Context is tertiary, the reason secondary.
    private var detailText: Text {
        var lead: [Text] = []
        if !item.ports.isEmpty {
            let ports = item.ports.map { ":\($0)" }.joined(separator: " ")
            lead.append(Text(verbatim: ports).font(Theme.mono(11)).foregroundStyle(Theme.tertiary))
        }
        // The scanner may already put ":8081 expo start" in the context: the ports are drawn once.
        let context = item.ports.isEmpty ? item.context : item.context?
            .replacing(/^(:\d+\s*)+/, with: "")
        if let context, !context.isEmpty {
            lead.append(Text(verbatim: context).foregroundStyle(Theme.tertiary))
        }
        var parts: [Text] = lead.isEmpty ? [] : [Self.join(lead, " ")]
        if isNotResponding {
            parts.append(Text("not responding").foregroundStyle(Theme.red))
        } else if let reason = item.reason {
            parts.append(Text(verbatim: format.reason(reason, now: now)).foregroundStyle(Theme.secondary))
        }
        return Self.join(parts, " · ")
    }

    private static func join(_ parts: [Text], _ separator: String) -> Text {
        guard var result = parts.first else { return Text(verbatim: "") }
        for part in parts.dropFirst() { result = Text("\(result)\(Text(verbatim: separator))\(part)") }
        return result
    }

    // MARK: Confirmation

    private var busy: Bool { item.isBusy && item.group == .claude }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(busy ? tr("Claude is answering") : tr("Stop \(item.name)?"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            consequence
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).buttonStyle(SmallButtonStyle())
                Button(busy ? "Stop anyway" : "Stop", action: onConfirm).buttonStyle(SmallButtonStyle(destructive: true))
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: Theme.hairline) }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var consequence: some View {
        switch item.group {
        case .simulators: Text("The app and its data stay installed.")
        case .servers: Text("The server stops; restart it from its terminal.")
        case .claude:
            // The command sits on its own line so it never breaks in the middle.
            VStack(alignment: .leading, spacing: 0) {
                Text("The conversation can be resumed with")
                Text(verbatim: "claude --resume.").font(Theme.mono(11))
            }
        case .apps: Text("Unsaved work may be lost.")
        }
    }
}
