import AppKit
import RunwayCore
import SwiftUI

struct PopoverView: View {
    let store: UsageStore

    /// QA: RUNWAY_SCREEN=settings opens on the settings view.
    @State private var showingSettings = ProcessInfo.processInfo.environment["RUNWAY_SCREEN"] == "settings"

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(onBack: { withAnimation(Theme.transition) { showingSettings = false } })
            } else {
                UsageView(store: store, onSettings: { withAnimation(Theme.transition) { showingSettings = true } })
            }
        }
        .transition(.opacity)
        .frame(width: Theme.popoverWidth)
        .modifier(PopoverSurface(glass: Cheatcodes.shared.theme == .glass))
        .onAppear { store.refresh(.popoverOpened) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.refresh(.popoverOpened)
        }
    }
}

/// The panel's shape, border and shadow are the system's (MenuBarExtra window, a glass panel on macOS 26):
/// solid mode only paints our background inside it, glass mode lets the system material show.
struct PopoverSurface: ViewModifier {
    var glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content
        } else {
            content.background(Theme.background)
        }
    }
}

// MARK: - Main view

struct UsageView: View {
    let store: UsageStore
    var onSettings: () -> Void

    private let format = RunwayFormat()

    /// Offline / expired: last values shown in tertiary.
    private var muted: Bool { store.state.isOffline || store.state == .expired }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = store.now()
            VStack(alignment: .leading, spacing: 0) {
                header(now: now)
                    .padding(Theme.padding)
                Hairline()
                VStack(alignment: .leading, spacing: 16) {
                    alert
                    if let snapshot = store.snapshot {
                        gauges(snapshot, now: now)
                    } else if store.state == .loading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(Theme.padding)
                if let credits = store.snapshot?.credits {
                    Hairline()
                    creditsRow(credits).padding(Theme.padding)
                }
                Hairline()
                footer
                    .padding(.horizontal, Theme.padding)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: Header

    /// Right-click opens the cheatcodes (theme, scenarios).
    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Runway")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.trailing, 2)
                if let plan = store.plan {
                    Pill(text: plan)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    IconButton(systemImage: "arrow.clockwise", help: tr("Refresh"), spinning: store.isRefreshing) {
                        store.refresh(.manual)
                    }
                    // gearshape draws smaller than arrow.clockwise at the same point size: 12.5 pt matches them.
                    IconButton(systemImage: "gearshape", size: 12.5, help: tr("Settings"), action: onSettings)
                }
            }
            .frame(height: 24)
            if let account = store.account {
                // The email gives way first: the account type is the part that answers "which plan is this".
                HStack(spacing: 0) {
                    if let email = account.email {
                        Text(email + " · ")
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    // "Team", "Enterprise", "Personal"; the organization name is in the tooltip.
                    Text(account.kind.label)
                        .layoutPriority(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .help(account.organizationName ?? "")
            }
            Text(subtitle(now: now))
                .font(.system(size: 11, weight: store.state.isOffline ? .medium : .regular))
                .foregroundStyle(store.state.isOffline ? AnyShapeStyle(Theme.red) : Theme.tertiary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .contextMenu { CheatcodeMenu(store: store) }
    }

    private func subtitle(now: Date) -> String {
        let ago = store.snapshot.map { format.ago($0.fetchedAt, now: now) }
        switch store.state {
        case .loading: return tr("Loading…")
        case .ok: return ago.map { tr("Updated \($0)") } ?? tr("Updated")
        case .offline(let reason):
            // 429: say when it comes back, the values' age is already implied by the muted gauges.
            if let until = store.throttledUntil {
                let message = reason.message, time = format.clock(until)
                return tr("\(message) · back at \(time)")
            }
            return [reason.message, ago].compactMap { $0 }.joined(separator: " · ")
        case .expired: return ago.map { tr("Last updated \($0)") } ?? tr("Connection expired")
        case .claudeCodeMissing: return tr("Claude Code not detected")
        }
    }

    // MARK: Alerts

    @ViewBuilder
    private var alert: some View {
        switch store.state {
        case .expired:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.amber).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text("Claude Code connection expired. Open Claude Code to renew it, Runway will pick up on its own.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .claudeCodeMissing:
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code isn’t installed on this Mac. Install it, then sign in:")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "claude")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
            }
        case .offline where store.snapshot == nil:
            // Nothing cached yet: the body would be empty, so say what happens instead.
            Text(store.throttledUntil.map {
                let time = format.clock($0)
                return tr("Claude is limiting how often usage can be read. Values will return at \(time).")
            } ?? tr("Can’t read usage right now. Runway will retry on its own in a few minutes."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    // MARK: Gauges

    private func gauges(_ snapshot: UsageSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionRow(snapshot, now: now)
            if let weekly = snapshot.weekly {
                weeklyRow(weekly, label: tr("Weekly"), now: now)
            }
            ForEach(snapshot.scoped) { limit in
                weeklyRow(limit, label: tr("Weekly · \(limit.modelName ?? tr("Model"))"), now: now)
            }
        }
    }

    /// A window that reset since the fetch shows 0 % and no date, until the next answer.
    private func weeklyRow(_ limit: UsageLimit, label: String, now: Date) -> some View {
        let percent = limit.percent(at: now)
        return GaugeRow(label: label, value: format.compactPercent(percent), percent: percent,
                        meta: limit.resetsAt.flatMap { $0 > now ? tr("Resets \(format.dayAndClock($0))") : nil }, muted: muted)
    }

    private func sessionRow(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let percent = snapshot.sessionPercent(at: now)
        var meta = tr("No session in progress")
        var projection: PaceProjection?
        if let resetsAt = snapshot.session?.resetsAt, resetsAt > now {
            meta = tr("Resets \(format.clock(resetsAt)) · \(format.countdown(to: resetsAt, now: now))")
            if !muted { projection = Pace.project(percent: percent, resetsAt: resetsAt, now: now) }
        }
        return GaugeRow(label: tr("Session"), value: format.compactPercent(percent), percent: percent, meta: meta,
                        muted: muted) {
            if let projection {
                let hits = if case .hitsLimit = projection { true } else { false }
                Text(format.paceLine(projection))
                    .font(.system(size: 11, weight: hits ? .medium : .regular))
                    .foregroundStyle(hits ? AnyShapeStyle(Theme.amber) : Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Credits

    private func creditsRow(_ credits: UsageCredits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage credits")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Group {
                    if let limit = credits.limit {
                        Text("\(format.money(credits.used, currency: credits.currency)) / \(format.money(limit, currency: credits.currency))")
                    } else {
                        Text(format.money(credits.used, currency: credits.currency))
                    }
                }
                .font(Theme.mono(13))
                .foregroundStyle(muted ? Theme.tertiary : Theme.text)
            }
            if credits.isCapReached {
                Pill(text: tr("Cap reached"), foreground: AnyShapeStyle(Theme.red),
                     background: AnyShapeStyle(Theme.red.opacity(0.10)), border: AnyShapeStyle(Theme.red.opacity(0.30)))
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Link(destination: URL(string: "https://claude.ai/settings/usage")!) {
                Text("Details on claude.ai ↗")
            }
            .modifier(HoverUnderline())
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .modifier(HoverUnderline())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
    }
}

/// Label (secondary 12) + mono value (13) / 4 pt gauge / meta (tertiary 11) / optional extra line.
struct GaugeRow<Extra: View>: View {
    var label: String
    var value: String
    var percent: Double
    var meta: String?
    var muted: Bool
    @ViewBuilder var extra: () -> Extra

    init(label: String, value: String, percent: Double, meta: String?, muted: Bool,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.label = label
        self.value = value
        self.percent = percent
        self.meta = meta
        self.muted = muted
        self.extra = extra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer()
                Text(value)
                    .font(Theme.mono(13, weight: .medium))
                    .foregroundStyle(muted ? Theme.tertiary : Theme.text)
                    .contentTransition(.numericText(value: percent))
                    .animation(Theme.transition, value: percent)
            }
            Gauge(percent: percent, muted: muted)
            VStack(alignment: .leading, spacing: 3) {
                if let meta {
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
                extra()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
