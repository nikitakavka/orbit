import SwiftUI
import OrbitCore

struct OrbitSettingsView: View {
    @ObservedObject var viewModel: OrbitSettingsViewModel
    @State private var selectedTab: Tab = .clusters

    enum Tab: String, CaseIterable, Identifiable {
        case clusters = "Clusters"
        case activity = "Activity Log"
        case about = "About"

        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [OrbitSettingsSkin.backgroundTop, OrbitSettingsSkin.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(OrbitTheme.accent.opacity(0.08))
                .blur(radius: 100)
                .frame(width: 420, height: 420)
                .offset(x: 260, y: -240)

            VStack(spacing: 14) {
                topBar

                Group {
                    switch selectedTab {
                    case .clusters:
                        clustersTab
                    case .activity:
                        activityTab
                    case .about:
                        aboutTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(18)
        }
        .frame(minWidth: 980, minHeight: 680)
        .onAppear {
            viewModel.reload()
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(OrbitTheme.sans(30, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textPrimary)

                Text("Shape Orbit around your cluster habits.")
                    .font(OrbitTheme.sans(13))
                    .foregroundStyle(OrbitTheme.textSecondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(OrbitTheme.sans(12, weight: .semibold))
                            .foregroundStyle(selectedTab == tab ? OrbitTheme.textPrimary : OrbitTheme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedTab == tab ? OrbitSettingsSkin.tabActive : OrbitSettingsSkin.tabIdle)
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(selectedTab == tab ? OrbitSettingsSkin.tabBorderStrong : OrbitSettingsSkin.tabBorder, lineWidth: 1)
                            }
                            .clipShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OrbitSettingsSkin.panel)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OrbitSettingsSkin.border, lineWidth: 1)
                }
        }
    }
}

enum OrbitSettingsSkin {
    static let backgroundTop = Color(hex: 0x131417)
    static let backgroundBottom = Color(hex: 0x1A1B20)

    static let panel = Color.white.opacity(0.045)
    static let panelStrong = Color.white.opacity(0.065)
    static let panelSoft = Color.white.opacity(0.038)

    static let border = Color.white.opacity(0.08)
    static let borderSoft = Color.white.opacity(0.06)

    static let tabIdle = Color.white.opacity(0.04)
    static let tabActive = OrbitTheme.accent.opacity(0.22)
    static let tabBorder = Color.white.opacity(0.08)
    static let tabBorderStrong = OrbitTheme.accent.opacity(0.35)

    static let field = Color.white.opacity(0.055)
    static let fieldBorder = Color.white.opacity(0.08)
}
