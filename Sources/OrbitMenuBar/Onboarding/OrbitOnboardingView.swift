import AppKit
import SwiftUI

struct OrbitOnboardingView: View {
    @ObservedObject var viewModel: OrbitOnboardingViewModel

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Orbit — Onboarding Flow · click through all screens")
                    .font(OrbitTheme.mono(9))
                    .foregroundStyle(Palette.t3)
                    .tracking(1.2)
                    .textCase(.uppercase)

                onboardingWindow
                dotNavigation
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 12)
        }
        .preferredColorScheme(.dark)
    }

    private var onboardingWindow: some View {
        VStack(spacing: 0) {
            switch viewModel.step {
            case .welcome:
                welcomeScreen
            case .startup:
                startupScreen
            case .cluster:
                clusterScreen
            case .sshKey:
                sshKeyScreen
            case .networkPermission:
                networkPermissionScreen
            case .testing:
                testingScreen
            case .notifications:
                notificationPermissionScreen
            case .done:
                successScreen
            }
        }
        .frame(width: 340)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.75), radius: 24, x: 0, y: 12)
        .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 0)
    }

    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            OrbitMark()
                .padding(.bottom, 24)

            Text("Orbit")
                .font(OrbitTheme.mono(22, weight: .medium))
                .foregroundStyle(Palette.t1)
                .tracking(1.2)
                .textCase(.uppercase)
                .padding(.bottom, 8)

            Text("HPC cluster monitoring for your menu bar. Connect once, watch always.")
                .font(OrbitTheme.sans(12, weight: .light))
                .foregroundStyle(Palette.t3)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .frame(maxWidth: 220)
                .padding(.bottom, 32)

            Button("Connect a cluster →") {
                viewModel.continueFromWelcome()
            }
            .buttonStyle(PrimaryButtonStyle())

        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private var startupScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Palette.orange.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Palette.orange.opacity(0.20), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: viewModel.isInstalledInApplications ? "power" : "folder.fill")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Palette.orange)
                    }
                    .frame(width: 52, height: 52)
                    .padding(.bottom, 18)

                Text(viewModel.isInstalledInApplications ? "STARTUP" : "INSTALLATION")
                    .font(OrbitTheme.mono(9))
                    .foregroundStyle(Palette.orange)
                    .tracking(1.2)
                    .padding(.bottom, 7)

                Text(startupTitle)
                    .font(OrbitTheme.mono(17, weight: .medium))
                    .foregroundStyle(Palette.t1)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 7)

                Text(startupSubtitle)
                    .font(OrbitTheme.sans(11, weight: .light))
                    .foregroundStyle(Palette.t3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2.5)
                    .frame(maxWidth: 250)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)

            if viewModel.isExistingConfigurationSetup {
                startupNoticeCard(
                    icon: "checkmark",
                    tint: Palette.green,
                    title: "Existing setup found",
                    detail: "Your cluster profiles, settings, and recent metrics will be kept."
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }

            if viewModel.isInstalledInApplications {
                installedStartupContent
            } else {
                outsideApplicationsContent
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshStartupStatus()
        }
    }

    private var startupTitle: String {
        if !viewModel.isInstalledInApplications {
            return "Move Orbit to Applications"
        }
        if viewModel.launchAtLoginEnabled {
            return "Ready when you are"
        }
        if viewModel.launchAtLoginRequiresApproval {
            return "One last approval"
        }
        return "Start Orbit automatically?"
    }

    private var startupSubtitle: String {
        if !viewModel.isInstalledInApplications {
            return viewModel.isRunningFromDownloads
                ? "Orbit is running from Downloads. Move it to Applications to enable launch at login and automatic updates."
                : "Orbit is running outside Applications. Move it there to enable launch at login and automatic updates."
        }
        if viewModel.launchAtLoginEnabled {
            return "Orbit will appear quietly in your menu bar whenever you log in."
        }
        if viewModel.launchAtLoginRequiresApproval {
            return "Orbit is registered, but macOS needs you to allow it in Login Items."
        }
        return "Orbit can appear quietly in your menu bar whenever you log in after restarting your Mac."
    }

    private var installedStartupContent: some View {
        VStack(spacing: 0) {
            startupLocationBadge
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            if viewModel.launchAtLoginEnabled {
                startupNoticeCard(
                    icon: "checkmark",
                    tint: Palette.green,
                    title: "Launch at Login is on",
                    detail: "No window will open — Orbit simply returns to the menu bar."
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                VStack(spacing: 8) {
                    Button("Continue →") {
                        viewModel.continueFromStartup()
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    startupBackButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            } else if viewModel.launchAtLoginRequiresApproval {
                startupNoticeCard(
                    icon: "exclamationmark",
                    tint: Palette.orange,
                    title: "Waiting for macOS",
                    detail: "Open Login Items and allow Orbit. Return here when you're done."
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                VStack(spacing: 7) {
                    Button("Open Login Items →") {
                        viewModel.openSystemLoginItemsSettings()
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button("Continue for now") {
                        viewModel.continueFromStartup()
                    }
                    .buttonStyle(GhostButtonStyle())

                    startupBackButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            } else {
                VStack(spacing: 8) {
                    startupFeatureRow(
                        icon: "power",
                        title: "Launch automatically",
                        detail: "Starts quietly when you log in"
                    )
                    startupFeatureRow(
                        icon: "menubar.rectangle",
                        title: "Menu bar only",
                        detail: "No window opens at startup"
                    )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)

                if let error = viewModel.launchAtLoginErrorMessage, !error.isEmpty {
                    startupNoticeCard(
                        icon: "exclamationmark",
                        tint: Palette.red,
                        title: "Could not enable startup",
                        detail: error
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
                }

                VStack(spacing: 7) {
                    Button(viewModel.isChangingLaunchAtLogin ? "Enabling…" : "Enable & continue →") {
                        viewModel.enableLaunchAtLoginAndContinue()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.isChangingLaunchAtLogin)
                    .opacity(viewModel.isChangingLaunchAtLogin ? 0.65 : 1)

                    Button("Not now") {
                        viewModel.continueFromStartup()
                    }
                    .buttonStyle(GhostButtonStyle())

                    startupBackButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var outsideApplicationsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                startupOrbitTile

                HStack(spacing: 3) {
                    Circle().fill(Palette.orange.opacity(0.28)).frame(width: 3, height: 3)
                    Rectangle().fill(Palette.orange.opacity(0.28)).frame(width: 14, height: 1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.orange.opacity(0.7))
                }

                startupFolderTile(icon: "folder.fill", label: "APPS")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Palette.t4)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Palette.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            VStack(spacing: 8) {
                startupFeatureRow(
                    icon: "power",
                    title: "Launch automatically",
                    detail: "Starts quietly when you log in"
                )
                startupFeatureRow(
                    icon: "arrow.down.circle",
                    title: "Automatic updates",
                    detail: "Install new versions inside Orbit"
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            VStack(spacing: 7) {
                Button("Open folders & quit") {
                    viewModel.quitAndShowInstallationFolders()
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Continue without moving") {
                    viewModel.continueFromStartup()
                }
                .buttonStyle(GhostButtonStyle())

                startupBackButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var startupLocationBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.green)
                .frame(width: 5, height: 5)

            Text(viewModel.installedApplicationDisplayPath)
                .font(OrbitTheme.mono(9))
                .foregroundStyle(Palette.green.opacity(0.78))
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("INSTALLED")
                .font(OrbitTheme.mono(8, weight: .medium))
                .foregroundStyle(Palette.t3)
                .tracking(0.7)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Palette.green.opacity(0.05))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Palette.green.opacity(0.13), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func startupFeatureRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.orange.opacity(0.08))
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.orange.opacity(0.85))
                }
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OrbitTheme.mono(10, weight: .medium))
                    .foregroundStyle(Palette.t1)

                Text(detail)
                    .font(OrbitTheme.sans(10, weight: .light))
                    .foregroundStyle(Palette.t3)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Palette.t4)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func startupNoticeCard(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint.opacity(0.13))
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(OrbitTheme.mono(10, weight: .medium))
                    .foregroundStyle(Palette.t1)

                Text(detail)
                    .font(OrbitTheme.sans(10, weight: .light))
                    .foregroundStyle(Palette.t3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background(tint.opacity(0.055))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.15), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var startupOrbitTile: some View {
        VStack(spacing: 5) {
            OrbitMark(size: 22, animated: false)

            Text("ORBIT")
                .font(OrbitTheme.mono(8, weight: .medium))
                .foregroundStyle(Palette.t3)
                .tracking(0.8)
        }
        .frame(width: 58, height: 48)
        .background(Palette.orange.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func startupFolderTile(icon: String, label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.orange)

            Text(label)
                .font(OrbitTheme.mono(8, weight: .medium))
                .foregroundStyle(Palette.t3)
                .tracking(0.8)
        }
        .frame(width: 58, height: 48)
        .background(Palette.orange.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var startupBackButton: some View {
        if !viewModel.isExistingConfigurationSetup {
            Button("← Back") {
                viewModel.back()
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    private var clusterScreen: some View {
        VStack(spacing: 0) {
            formHeader(stepText: "Step 1 of 4", title: "Your cluster", subtitle: "Where should Orbit connect?")

            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    field(label: "Username", placeholder: "your_username", text: $viewModel.username)
                    field(label: "Hostname", placeholder: "cluster.example.edu", text: $viewModel.hostname)
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Port (optional, default 22)")
                        .font(OrbitTheme.mono(9))
                        .foregroundStyle(Palette.t3)
                        .tracking(0.8)
                        .textCase(.uppercase)

                    TextField("22", text: $viewModel.port)
                        .textFieldStyle(.plain)
                        .font(OrbitTheme.mono(12))
                        .foregroundStyle(Palette.t1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Palette.t4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Palette.border, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .frame(width: 80, alignment: .leading)
                }

                if let formError = viewModel.formError {
                    Text(formError)
                        .font(OrbitTheme.sans(11, weight: .light))
                        .foregroundStyle(Palette.red.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)

            VStack(spacing: 8) {
                Button("Find SSH keys →") {
                    viewModel.continueFromCluster()
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("← Back") {
                    viewModel.back()
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    private var sshKeyScreen: some View {
        VStack(spacing: 0) {
            formHeader(stepText: "Step 2 of 4", title: "SSH key", subtitle: "Found these in ~/.ssh — pick the right one.")

            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.info)
                    .frame(width: 5, height: 5)

                Text(viewModel.keyScanSummary)
                    .font(OrbitTheme.mono(10))
                    .foregroundStyle(Palette.info.opacity(0.8))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Palette.info.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Palette.info.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.top, 20)

            VStack(spacing: 6) {
                if viewModel.discoveredKeys.isEmpty {
                    Text("No keys found in ~/.ssh")
                        .font(OrbitTheme.mono(10))
                        .foregroundStyle(Palette.t3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }

                ForEach(viewModel.discoveredKeys) { key in
                    keyOption(key)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Button(viewModel.isManualPathEntryVisible ? "− Hide manual path" : "+ Enter path manually") {
                viewModel.toggleManualPathEntry()
            }
            .buttonStyle(.plain)
            .font(OrbitTheme.mono(10))
            .foregroundStyle(Palette.t3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 2)

            if viewModel.isManualPathEntryVisible {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SSH key path")
                        .font(OrbitTheme.mono(9))
                        .foregroundStyle(Palette.t3)
                        .tracking(0.8)
                        .textCase(.uppercase)

                    TextField("~/.ssh/id_ed25519", text: $viewModel.manualKeyPath)
                        .textFieldStyle(.plain)
                        .font(OrbitTheme.mono(12))
                        .foregroundStyle(Palette.t1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Palette.t4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Palette.border, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }

            if let testError = viewModel.testErrorMessage, !testError.isEmpty {
                Text(testError)
                    .font(OrbitTheme.sans(11, weight: .light))
                    .foregroundStyle(Palette.red.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            VStack(spacing: 8) {
                Button("Continue →") {
                    viewModel.continueFromSSHKey()
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("← Back") {
                    viewModel.back()
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    private var networkPermissionScreen: some View {
        VStack(spacing: 0) {
            formHeader(
                stepText: "Step 3 of 4",
                title: "Network access",
                subtitle: "macOS may ask permission before Orbit connects."
            )

            VStack(spacing: 0) {
                permissionNoticeRow(
                    number: 1,
                    message: Text("macOS will ask to allow an outgoing SSH connection.")
                )

                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)
                    .padding(.horizontal, 10)

                permissionNoticeRow(
                    number: 2,
                    message: Text("Click ") + Text("Allow").foregroundColor(Palette.t1) + Text(" — no data leaves your machine except the SSH handshake.")
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Palette.t4)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.top, 18)


            VStack(spacing: 8) {
                Button("Test connection →") {
                    viewModel.continueAfterNetworkPermissionPrompt()
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("← Back") {
                    viewModel.back()
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    private func permissionNoticeRow(number: Int, message: Text) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                .overlay {
                    Text("\(number)")
                        .font(OrbitTheme.mono(8))
                        .foregroundStyle(Palette.t3)
                }
                .frame(width: 16, height: 16)

            message
                .font(OrbitTheme.sans(11, weight: .light))
                .foregroundStyle(Palette.t2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var testingScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(viewModel.clusterUser)
                    .font(OrbitTheme.mono(13))
                    .foregroundStyle(Palette.t2)

                Text("@")
                    .font(OrbitTheme.mono(13))
                    .foregroundStyle(Palette.t3)

                Text(viewModel.clusterHost)
                    .font(OrbitTheme.mono(13, weight: .medium))
                    .foregroundStyle(Palette.t1)
            }
            .padding(.bottom, 24)

            VStack(spacing: 10) {
                ForEach(OrbitOnboardingViewModel.ConnectionStepID.allCases, id: \.self) { id in
                    let status = viewModel.status(for: id)
                    HStack(spacing: 10) {
                        stepIcon(for: status.state)
                        Text(status.label)
                            .font(OrbitTheme.mono(11))
                            .foregroundStyle(stepLabelColor(for: status.state))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.bottom, 24)

            if let help = viewModel.testHelpMessage, !help.isEmpty {
                Text(help)
                    .font(OrbitTheme.sans(11, weight: .light))
                    .foregroundStyle(Palette.orange.opacity(0.85))
                    .lineSpacing(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.orange.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Palette.orange.opacity(0.15), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.bottom, 16)
            }

            if let error = viewModel.testErrorMessage, !error.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connection failed")
                        .font(OrbitTheme.mono(10))
                        .foregroundStyle(Palette.red)

                    Text(error)
                        .font(OrbitTheme.sans(11, weight: .light))
                        .foregroundStyle(Palette.red.opacity(0.7))
                        .lineSpacing(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Palette.red.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Palette.red.opacity(0.15), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.bottom, 16)
            }

            if viewModel.canContinueAfterTest {
                Button("Continue to notifications →") {
                    viewModel.continueAfterSuccessfulTest()
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.bottom, 4)
            } else if viewModel.testErrorMessage != nil, !viewModel.isTestingConnection {
                Button("Retry connection →") {
                    viewModel.startConnectionTest()
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.bottom, 4)
            }

            Button(viewModel.isTestingConnection ? "Cancel and edit connection" : "Edit connection") {
                viewModel.back()
            }
            .buttonStyle(GhostButtonStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    private var notificationPermissionScreen: some View {
        let permissionGranted = viewModel.notificationPermissionState.isGranted

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.orange.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Palette.orange.opacity(0.18), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "bell")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Palette.orange)
                    }
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Step 4 of 4")
                        .font(OrbitTheme.mono(9))
                        .foregroundStyle(Palette.orange)
                        .tracking(1)
                        .textCase(.uppercase)

                    Text("Notifications")
                        .font(OrbitTheme.mono(16, weight: .medium))
                        .foregroundStyle(Palette.t1)

                    Text("Orbit will alert you when jobs finish, fail, or are close to their walltime.")
                        .font(OrbitTheme.sans(11, weight: .light))
                        .foregroundStyle(Palette.t3)
                        .lineSpacing(2.5)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    permissionUseRow("Job completion & failure")
                    permissionUseRow("Walltime warnings before timeout")
                }

                Rectangle()
                    .fill(Palette.border)
                    .frame(height: 1)

                permissionStatusRow(granted: permissionGranted)

                VStack(spacing: 6) {
                    switch viewModel.notificationPermissionState {
                    case .granted:
                        Button("Continue →") {
                            viewModel.continueFromNotificationPermission()
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button("← Back") {
                            viewModel.back()
                        }
                        .buttonStyle(GhostButtonStyle())

                    case .notDetermined:
                        Button(viewModel.isRequestingNotificationPermission ? "Requesting…" : "Allow notifications →") {
                            viewModel.requestNotificationPermission()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(viewModel.isRequestingNotificationPermission)
                        .opacity(viewModel.isRequestingNotificationPermission ? 0.65 : 1)

                        Button("Skip for now") {
                            viewModel.skipNotificationPermissionStep()
                        }
                        .buttonStyle(GhostButtonStyle())

                    case .denied:
                        Button("Open Notification Settings →") {
                            viewModel.openSystemNotificationSettings()
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button("Continue without notifications") {
                            viewModel.skipNotificationPermissionStep()
                        }
                        .buttonStyle(GhostButtonStyle())

                    case .checking, .unknown:
                        Button("Check permission again") {
                            viewModel.refreshNotificationPermissionStatus()
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button("Skip for now") {
                            viewModel.skipNotificationPermissionStep()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
        .onAppear {
            viewModel.refreshNotificationPermissionStatus()
        }
    }

    private func permissionUseRow(_ text: String) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Palette.orange)
                .frame(width: 4, height: 4)

            Text(text)
                .font(OrbitTheme.sans(11, weight: .light))
                .foregroundStyle(Palette.t2)

            Spacer(minLength: 0)
        }
    }

    private func permissionStatusRow(granted: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? Palette.green : Palette.orange)
                .frame(width: 5, height: 5)

            Text(viewModel.notificationPermissionState.statusText)
                .font(OrbitTheme.mono(10))
                .foregroundStyle((granted ? Palette.green : Palette.orange).opacity(0.75))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background((granted ? Palette.green : Palette.orange).opacity(0.05))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke((granted ? Palette.green : Palette.orange).opacity(0.15), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var successScreen: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Palette.green.opacity(0.1))
                    .overlay {
                        Circle().stroke(Palette.green.opacity(0.25), lineWidth: 1.5)
                    }

                Text("✓")
                    .font(OrbitTheme.mono(20, weight: .medium))
                    .foregroundStyle(Palette.green)
            }
            .frame(width: 56, height: 56)
            .padding(.bottom, 20)

            Text(viewModel.isExistingConfigurationSetup ? "Orbit is ready" : "You're in orbit")
                .font(OrbitTheme.mono(17, weight: .medium))
                .foregroundStyle(Palette.t1)
                .padding(.bottom, 6)

            Text(
                viewModel.isExistingConfigurationSetup
                    ? "Your existing clusters and recent metrics are ready in the redesigned Orbit."
                    : "Orbit is now watching your cluster from the menu bar. It will notify you when jobs finish or hit their walltime."
            )
                .font(OrbitTheme.sans(11, weight: .light))
                .foregroundStyle(Palette.t3)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .padding(.bottom, 8)

            Text(viewModel.clusterDisplayLine)
                .font(OrbitTheme.mono(11))
                .foregroundStyle(Palette.t2)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Palette.t4)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.bottom, 28)

            Button("Open Orbit") {
                viewModel.finishAndOpenOrbit()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
    }

    private var dotNavigation: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.navigationSteps, id: \.rawValue) { step in
                let active = step == viewModel.step
                let reachable = viewModel.isStepReachableInNavigation(step)
                let visited = reachable && !active

                Button {
                    viewModel.navigateToStep(step)
                } label: {
                    Capsule(style: .continuous)
                        .fill(active ? Palette.orange : (visited ? Palette.green.opacity(0.5) : Palette.t3))
                        .frame(width: active ? 14 : 5, height: 5)
                }
                .buttonStyle(.plain)
                .disabled(!reachable)
                .opacity(reachable ? 1 : 0.45)
            }
        }
    }

    private func formHeader(stepText: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(stepText)
                .font(OrbitTheme.mono(9))
                .foregroundStyle(Palette.orange)
                .tracking(1)
                .textCase(.uppercase)
                .padding(.bottom, 6)

            Text(title)
                .font(OrbitTheme.mono(16, weight: .medium))
                .foregroundStyle(Palette.t1)
                .padding(.bottom, 4)

            Text(subtitle)
                .font(OrbitTheme.sans(11, weight: .light))
                .foregroundStyle(Palette.t3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(OrbitTheme.mono(9))
                .foregroundStyle(Palette.t3)
                .tracking(0.8)
                .textCase(.uppercase)

            TextField("", text: text, prompt: Text(placeholder).foregroundColor(Palette.t3))
                .textFieldStyle(.plain)
                .font(OrbitTheme.mono(12))
                .foregroundStyle(Palette.t1)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Palette.t4)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Palette.border, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func keyOption(_ key: OrbitOnboardingViewModel.SSHKeyOption) -> some View {
        let isSelected = viewModel.selectedKeyPath == key.path

        return Button {
            viewModel.chooseKey(path: key.path)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Palette.orange : Palette.t3, lineWidth: 1.5)
                        .frame(width: 14, height: 14)

                    Circle()
                        .fill(Palette.orange)
                        .frame(width: 6, height: 6)
                        .opacity(isSelected ? 1 : 0)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(key.name)
                        .font(OrbitTheme.mono(11))
                        .foregroundStyle(Palette.t1)
                        .lineLimit(1)

                    Text(key.displayPath)
                        .font(OrbitTheme.mono(9))
                        .foregroundStyle(Palette.t3)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.orange.opacity(0.06) : Palette.t4)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Palette.orange.opacity(0.35) : Palette.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func stepIcon(for state: OrbitOnboardingViewModel.ConnectionStepState) -> some View {
        ZStack {
            Circle()
                .fill(stepIconBackground(for: state))

            switch state {
            case .done:
                Text("✓")
                    .font(OrbitTheme.mono(10, weight: .medium))
                    .foregroundStyle(Palette.green)
            case .running:
                SpinnerGlyph()
                    .font(OrbitTheme.mono(10, weight: .medium))
                    .foregroundStyle(Palette.orange)
            case .waiting:
                Text("·")
                    .font(OrbitTheme.mono(12, weight: .medium))
                    .foregroundStyle(Palette.t3)
            case .fail:
                Text("✕")
                    .font(OrbitTheme.mono(10, weight: .medium))
                    .foregroundStyle(Palette.red)
            }
        }
        .frame(width: 20, height: 20)
    }

    private func stepIconBackground(for state: OrbitOnboardingViewModel.ConnectionStepState) -> Color {
        switch state {
        case .done: return Palette.green.opacity(0.15)
        case .running: return Palette.orange.opacity(0.12)
        case .waiting: return Color.white.opacity(0.05)
        case .fail: return Palette.red.opacity(0.12)
        }
    }

    private func stepLabelColor(for state: OrbitOnboardingViewModel.ConnectionStepState) -> Color {
        switch state {
        case .done, .running: return Palette.t1
        case .waiting: return Palette.t2
        case .fail: return Palette.red
        }
    }
}

private enum Palette {
    static let bg = Color(hex: 0x0C0C0D)
    static let surface = Color(hex: 0x161618)
    static let border = Color.white.opacity(0.07)

    static let orange = Color(hex: 0xFF6B35)
    static let green = Color(hex: 0x4ADE80)
    static let red = Color(hex: 0xF87171)
    static let info = Color(hex: 0x63B3ED)

    static let t1 = Color.white.opacity(0.88)
    static let t2 = Color.white.opacity(0.45)
    static let t3 = Color.white.opacity(0.22)
    static let t4 = Color.white.opacity(0.06)
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrbitTheme.mono(11, weight: .medium))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(Color(hex: 0x0C0C0D))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(configuration.isPressed ? Color(hex: 0xFF8555) : Palette.orange)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrbitTheme.mono(10))
            .tracking(0.6)
            .foregroundStyle(configuration.isPressed ? Palette.t2 : Palette.t3)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
    }
}

private struct SpinnerGlyph: View {
    @State private var rotating = false

    var body: some View {
        Text("◌")
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotating = true
                }
            }
    }
}

private struct OrbitMark: View {
    private static let designSize: CGFloat = 512
    private static let ringWidth: CGFloat = 380
    private static let ringHeight: CGFloat = 140
    private static let ringStrokeWidth: CGFloat = 28
    private static let cutStrokeWidth: CGFloat = 18
    private static let coreDiameter: CGFloat = 60
    private static let declaredPathLength: CGFloat = 976
    private static let cutLength: CGFloat = 108
    private static let gapLength: CGFloat = 380
    private static let animationDuration: TimeInterval = 9

    let size: CGFloat
    let animated: Bool
    @State private var animationStartedAt = Date()

    init(size: CGFloat = 72, animated: Bool = true) {
        self.size = size
        self.animated = animated
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let scale = side / Self.designSize
                let ringRect = CGRect(
                    x: (geo.size.width - (Self.ringWidth * scale)) / 2.0,
                    y: (geo.size.height - (Self.ringHeight * scale)) / 2.0,
                    width: Self.ringWidth * scale,
                    height: Self.ringHeight * scale
                )

                // SVG's pathLength=976 scales the 108/380 dash pattern onto the
                // ellipse. Converting those values to the real perimeter keeps
                // two cuts exactly opposite and prevents a visible seam.
                let perimeter = ellipsePerimeter(
                    radiusX: ringRect.width / 2.0,
                    radiusY: ringRect.height / 2.0
                )
                let pathUnit = perimeter / Self.declaredPathLength
                let dashOn = Self.cutLength * pathUnit
                let dashOff = Self.gapLength * pathUnit
                let elapsed = max(0, timeline.date.timeIntervalSince(animationStartedAt))
                let progress = animated
                    ? elapsed.truncatingRemainder(dividingBy: Self.animationDuration) / Self.animationDuration
                    : 0
                let orbitPhase = -CGFloat(progress) * (dashOn + dashOff)

                ZStack {
                    ZStack {
                        Path { path in
                            path.addEllipse(in: ringRect)
                        }
                        .stroke(Palette.orange, lineWidth: Self.ringStrokeWidth * scale)

                        Path { path in
                            path.addEllipse(in: ringRect)
                        }
                        .stroke(
                            Palette.surface,
                            style: StrokeStyle(
                                lineWidth: Self.cutStrokeWidth * scale,
                                lineCap: .round,
                                dash: [dashOn, dashOff],
                                dashPhase: orbitPhase
                            )
                        )
                    }
                    .rotationEffect(.degrees(-25))

                    Circle()
                        .fill(Palette.orange)
                        .frame(
                            width: Self.coreDiameter * scale,
                            height: Self.coreDiameter * scale
                        )
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func ellipsePerimeter(radiusX: CGFloat, radiusY: CGFloat) -> CGFloat {
        // Ramanujan's second approximation is effectively exact at this scale.
        let sum = radiusX + radiusY
        let h = pow((radiusX - radiusY) / sum, 2)
        return .pi * sum * (1 + ((3 * h) / (10 + sqrt(4 - (3 * h)))))
    }
}
