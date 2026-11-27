import RunwayCore
import SwiftUI

struct SettingsView: View {
    var onBack: () -> Void

    @AppStorage(PrefKey.sessionThresholds) private var sessionCSV = Preferences.defaultThresholds
    @AppStorage(PrefKey.weeklyThresholds) private var weeklyCSV = Preferences.defaultThresholds
    @AppStorage(PrefKey.menuBarMode) private var menuBarMode = MenuBarMode.session.rawValue
    @AppStorage(PrefKey.notifySessionReset) private var notifySessionReset = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconButton(systemImage: "chevron.left", help: tr("Back"), action: onBack)
                    .padding(.leading, -6)
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .frame(height: 24)
            .padding(Theme.padding)

            Hairline()

            VStack(alignment: .leading, spacing: 20) {
                section(Text("Notifications")) {
                    ThresholdRow(title: tr("Session"), csv: $sessionCSV)
                    ThresholdRow(title: tr("Weekly"), csv: $weeklyCSV)
                    Toggle("Notify when the session resets", isOn: $notifySessionReset)
                }
                section(Text("Menu bar")) {
                    SegmentedControl(selection: $menuBarMode)
                }
                section(Text(verbatim: ["Runway", Updater.version].compactMap { $0 }.joined(separator: " "))) {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            if !LaunchAtLogin.set(newValue) { launchAtLogin = LaunchAtLogin.isEnabled }
                        }
                    Button("Check for Updates…", action: updater.checkForUpdates)
                        .buttonStyle(SmallButtonStyle(fill: true))
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            .toggleStyle(MonoToggleStyle())
            .padding(Theme.padding)
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func section<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            content()
        }
    }
}

/// "Session   [50%] [80%] [95%]" — bordered pills, active = inverted.
struct ThresholdRow: View {
    var title: String
    @Binding var csv: String

    var body: some View {
        let selected = Set(NotifierSettings.parseThresholds(csv))
        HStack {
            Text(title)
                .font(Theme.rowFont)
                .foregroundStyle(Theme.text)
            Spacer()
            HStack(spacing: 6) {
                ForEach(NotifierSettings.defaultThresholds, id: \.self) { t in
                    let isOn = selected.contains(t)
                    Button {
                        var next = selected
                        if isOn { next.remove(t) } else { next.insert(t) }
                        withAnimation(Theme.transition) {
                            csv = NotifierSettings.encodeThresholds(Array(next))
                        }
                    } label: {
                        Text(verbatim: "\(t)%")
                            .font(Theme.mono(11, weight: .medium))
                            .foregroundStyle(isOn ? Theme.background : Theme.secondary)
                            .frame(width: 40, height: 22)
                            .background(isOn ? Theme.text : Theme.clear, in: .rect(cornerRadius: Theme.pillRadius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.pillRadius)
                                .strokeBorder(isOn ? Theme.text : Theme.border, lineWidth: 1))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("\(title) \(t)%"))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }
}

/// Bordered segmented control for the menu bar display mode.
struct SegmentedControl: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarMode.allCases) { mode in
                let isOn = selection == mode.rawValue
                Button {
                    withAnimation(Theme.transition) { selection = mode.rawValue }
                } label: {
                    Text(mode.label)
                        .font(.system(size: 12, weight: isOn ? .medium : .regular))
                        .foregroundStyle(isOn ? Theme.text : Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(isOn ? Theme.track : Theme.clear, in: .rect(cornerRadius: Theme.pillRadius))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}
