import SwiftUI
import OrbitCore

extension OrbitSettingsView {
    var clustersTab: some View {
        HStack(spacing: 14) {
            profilesPanel
                .frame(width: 270)

            profileEditorPanel
        }
    }

    private var profilesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cluster Profiles")
                        .font(OrbitTheme.sans(16, weight: .semibold))
                        .foregroundStyle(OrbitTheme.textPrimary)

                    Text("Choose a profile or create a new one")
                        .font(OrbitTheme.sans(11))
                        .foregroundStyle(OrbitTheme.textSecondary)
                }

                Spacer()

                Button {
                    viewModel.beginCreateProfile()
                } label: {
                    Label("New", systemImage: "plus.circle.fill")
                        .font(OrbitTheme.sans(11, weight: .semibold))
                }
                .buttonStyle(OrganicGhostButtonStyle(tint: OrbitTheme.accent))
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.profiles, id: \.id) { profile in
                        profileRow(profile)
                    }
                }
                .padding(.vertical, 2)
            }

            Rectangle()
                .fill(OrbitSettingsSkin.borderSoft)
                .frame(height: 1)

            HStack(spacing: 8) {
                Button("Reload") {
                    viewModel.reload()
                }
                .buttonStyle(OrganicGhostButtonStyle())

                Button("Delete") {
                    viewModel.deleteSelectedProfile()
                }
                .buttonStyle(OrganicGhostButtonStyle(tint: OrbitTheme.danger))
                .disabled(viewModel.selectedProfileID == nil)
            }
        }
        .padding(14)
        .background(panelCard(strong: true))
    }

    private func profileRow(_ profile: ClusterProfile) -> some View {
        let selected = profile.id == viewModel.selectedProfileID && !viewModel.isCreatingNew

        return Button {
            viewModel.selectProfile(profile.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "leaf.fill" : "leaf")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? OrbitTheme.accent : OrbitTheme.textTimestamp)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(OrbitTheme.sans(12, weight: .semibold))
                        .foregroundStyle(selected ? OrbitTheme.textPrimary : OrbitTheme.textSecondary)
                        .lineLimit(1)

                    Text(profile.hostname)
                        .font(OrbitTheme.mono(10))
                        .foregroundStyle(OrbitTheme.textTimestamp)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text(profile.isActive ? "active" : "paused")
                    .font(OrbitTheme.sans(9, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(profile.isActive ? OrbitTheme.success : OrbitTheme.textTimestamp)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((profile.isActive ? OrbitTheme.success : OrbitTheme.textTimestamp).opacity(0.16))
                    .clipShape(Capsule(style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(selected ? OrbitTheme.accent.opacity(0.16) : OrbitSettingsSkin.panelSoft)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? OrbitTheme.accent.opacity(0.45) : OrbitSettingsSkin.borderSoft, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var profileEditorPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.isCreatingNew ? "New Profile" : "Profile Details")
                            .font(OrbitTheme.sans(18, weight: .semibold))
                            .foregroundStyle(OrbitTheme.textPrimary)

                        Text(viewModel.isCreatingNew ? "Define how Orbit should connect to this cluster." : "Tune connection, polling, notifications and integrations.")
                            .font(OrbitTheme.sans(12))
                            .foregroundStyle(OrbitTheme.textSecondary)
                    }

                    Spacer(minLength: 8)

                    if let selected = viewModel.profiles.first(where: { $0.id == viewModel.selectedProfileID }), !viewModel.isCreatingNew {
                        Text(selected.displayName)
                            .font(OrbitTheme.sans(11, weight: .semibold))
                            .foregroundStyle(OrbitTheme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(OrbitTheme.accent.opacity(0.14))
                            .clipShape(Capsule(style: .continuous))
                    }
                }

                organicSection("Connection") {
                    LazyVGrid(columns: profileColumns, spacing: 12) {
                        organicField("Display Name", text: $viewModel.draft.displayName, placeholder: "Main Cluster")
                        organicField("Hostname", text: $viewModel.draft.hostname, placeholder: "cluster.example.edu")
                        organicField("Username", text: $viewModel.draft.username, placeholder: "your_username")
                        organicField("Port", text: $viewModel.draft.port, placeholder: "22")
                    }

                    organicField("SSH Key Path", text: $viewModel.draft.sshKeyPath, placeholder: "~/.ssh/id_ed25519")

                    organicToggle("Use ~/.ssh/config", isOn: $viewModel.draft.useSSHConfig)
                }

                organicSection("Polling & Alerts") {
                    LazyVGrid(columns: profileColumns, spacing: 12) {
                        organicField("Poll Interval (s)", text: $viewModel.draft.pollIntervalSeconds)
                        organicField("Extended Poll (s)", text: $viewModel.draft.extendedPollIntervalSeconds)
                        organicField("Time Warning (min)", text: $viewModel.draft.notifyOnTimeWarningMinutes)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        organicToggle("Show fairshare", isOn: $viewModel.draft.fairshareEnabled)
                        organicToggle("Notify on complete", isOn: $viewModel.draft.notifyOnComplete)
                        organicToggle("Notify on fail / timeout / OOM", isOn: $viewModel.draft.notifyOnFail)
                        organicToggle("Profile active", isOn: $viewModel.draft.isActive)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: viewModel.systemNotificationsAllowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(viewModel.systemNotificationsAllowed ? OrbitTheme.success : OrbitTheme.warning)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("macOS notification permission: \(viewModel.systemNotificationStatusText)")
                                    .font(OrbitTheme.sans(11, weight: .semibold))
                                    .foregroundStyle(OrbitTheme.textSecondary)

                                if !viewModel.systemNotificationStatusHint.isEmpty {
                                    Text(viewModel.systemNotificationStatusHint)
                                        .font(OrbitTheme.sans(11))
                                        .foregroundStyle(OrbitTheme.textTimestamp)
                                }

                                if !viewModel.systemNotificationsAllowed {
                                    Button("Open macOS Notification Settings") {
                                        viewModel.openSystemNotificationSettings()
                                    }
                                    .buttonStyle(OrganicGhostButtonStyle(tint: OrbitTheme.accent))
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                organicSection("Resource Economics") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            organicField("CPU-hour Cost ($ / CPU·h)", text: $viewModel.cpuHourRateText)
                            Button("Save Rate") {
                                viewModel.saveCPUHourRate()
                            }
                            .buttonStyle(OrganicGhostButtonStyle(tint: OrbitTheme.accent))
                        }

                        HStack(spacing: 10) {
                            organicField("Max command output cap (MB)", text: $viewModel.maxCommandOutputMBText)
                            Button("Save Cap") {
                                viewModel.saveMaxCommandOutputMB()
                            }
                            .buttonStyle(OrganicGhostButtonStyle(tint: OrbitTheme.accent))
                        }

                        Text("Environment variable ORBIT_MAX_COMMAND_OUTPUT_MB overrides this value.")
                            .font(OrbitTheme.sans(11))
                            .foregroundStyle(OrbitTheme.textTimestamp)
                    }
                }

                HStack(spacing: 10) {
                    Button(viewModel.isCreatingNew ? "Create Profile" : "Save Changes") {
                        viewModel.saveDraft()
                    }
                    .buttonStyle(OrganicFilledButtonStyle())

                    Button(viewModel.isBusy ? "Testing…" : "Test Connection") {
                        viewModel.testConnectionForSelectedProfile()
                    }
                    .buttonStyle(OrganicGhostButtonStyle())
                    .disabled(viewModel.selectedProfileID == nil || viewModel.isCreatingNew || viewModel.isBusy)

                    Spacer(minLength: 0)
                }

                if let message = viewModel.message, !message.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OrbitTheme.accent)

                        Text(message)
                            .font(OrbitTheme.sans(12))
                            .foregroundStyle(OrbitTheme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(OrbitTheme.accent.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OrbitTheme.accent.opacity(0.20), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(panelCard(strong: true))
    }

    var activityTab: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity Log")
                            .font(OrbitTheme.sans(17, weight: .semibold))
                            .foregroundStyle(OrbitTheme.textPrimary)

                        Text("A transparent feed of commands Orbit runs.")
                            .font(OrbitTheme.sans(12))
                            .foregroundStyle(OrbitTheme.textSecondary)
                    }

                    Spacer()

                    Button("Refresh") {
                        viewModel.reloadAudit()
                    }
                    .buttonStyle(OrganicGhostButtonStyle(tint: OrbitTheme.accent))
                    .disabled(!viewModel.auditEnabled)
                }

                HStack {
                    organicToggle(
                        "Enable audit logging",
                        isOn: Binding(
                            get: { viewModel.auditEnabled },
                            set: { viewModel.setAuditEnabled($0) }
                        )
                    )

                    Spacer(minLength: 14)

                    Stepper(value: $viewModel.auditLimit, in: 10...500, step: 10) {
                        Text("Show last \(viewModel.auditLimit)")
                            .font(OrbitTheme.sans(12))
                            .foregroundStyle(OrbitTheme.textSecondary)
                    }
                    .labelsHidden()
                    .disabled(!viewModel.auditEnabled)

                    Text("last \(viewModel.auditLimit)")
                        .font(OrbitTheme.mono(11))
                        .foregroundStyle(OrbitTheme.textSecondary)
                        .frame(minWidth: 70, alignment: .trailing)
                        .opacity(viewModel.auditEnabled ? 1 : 0.35)
                }

                Text("Off by default. Enable only if you need a command trail.")
                    .font(OrbitTheme.sans(11))
                    .foregroundStyle(OrbitTheme.textTimestamp)
            }
            .padding(16)
            .background(panelCard(strong: true))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !viewModel.auditEnabled {
                        emptyAuditState(text: "Audit logging is disabled. Enable it above to start collecting entries.")
                    } else if viewModel.auditEntries.isEmpty {
                        emptyAuditState(text: "No audit entries yet.")
                    } else {
                        ForEach(viewModel.auditEntries, id: \.id) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(row.timestamp)
                                        .font(OrbitTheme.mono(10))
                                        .foregroundStyle(OrbitTheme.textTimestamp)

                                    Text(row.cluster_name)
                                        .font(OrbitTheme.sans(12, weight: .semibold))
                                        .foregroundStyle(OrbitTheme.textSecondary)

                                    Spacer()

                                    Text(auditStatus(row))
                                        .font(OrbitTheme.sans(10, weight: .semibold))
                                        .foregroundStyle(auditColor(row))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(auditColor(row).opacity(0.16))
                                        .clipShape(Capsule(style: .continuous))

                                    if let duration = row.duration_ms {
                                        Text("\(duration)ms")
                                            .font(OrbitTheme.mono(10))
                                            .foregroundStyle(OrbitTheme.textTimestamp)
                                    }
                                }

                                Text(row.command)
                                    .font(OrbitTheme.mono(11))
                                    .foregroundStyle(OrbitTheme.textPrimary)
                                    .textSelection(.enabled)

                                if let error = row.error, !error.isEmpty {
                                    Text(error)
                                        .font(OrbitTheme.sans(11))
                                        .foregroundStyle(OrbitTheme.warning)
                                        .lineLimit(3)
                                }
                            }
                            .padding(10)
                            .background(OrbitSettingsSkin.panelSoft)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(OrbitSettingsSkin.borderSoft, lineWidth: 1)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .padding(16)
            }
            .background(panelCard(strong: true))
        }
        .onChange(of: viewModel.auditLimit) { _ in
            viewModel.reloadAudit()
        }
    }

    var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Orbit")
                        .font(OrbitTheme.sans(22, weight: .semibold))
                        .foregroundStyle(OrbitTheme.textPrimary)

                    Text("Commands Orbit may run on your cluster")
                        .font(OrbitTheme.sans(13))
                        .foregroundStyle(OrbitTheme.textSecondary)
                }

                ForEach(viewModel.commandTransparencyList, id: \.self) { command in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OrbitTheme.accent.opacity(0.85))
                            .padding(.top, 2)

                        Text(command)
                            .font(OrbitTheme.mono(11))
                            .foregroundStyle(OrbitTheme.textSecondary)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(OrbitSettingsSkin.panelSoft)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OrbitSettingsSkin.borderSoft, lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(panelCard(strong: true))
    }

    private var profileColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 170), spacing: 12),
            GridItem(.flexible(minimum: 170), spacing: 12)
        ]
    }

    @ViewBuilder
    private func organicSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(OrbitTheme.sans(13, weight: .semibold))
                .foregroundStyle(OrbitTheme.textPrimary)

            content()
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OrbitSettingsSkin.panelSoft)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OrbitSettingsSkin.borderSoft, lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func organicField(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(OrbitTheme.sans(11, weight: .semibold))
                .foregroundStyle(OrbitTheme.textLabel)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(OrbitTheme.sans(13))
                .foregroundStyle(OrbitTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(OrbitSettingsSkin.field)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(OrbitSettingsSkin.fieldBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    @ViewBuilder
    private func organicToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(OrbitTheme.sans(12))
                .foregroundStyle(OrbitTheme.textSecondary)
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func emptyAuditState(text: String) -> some View {
        Text(text)
            .font(OrbitTheme.sans(12))
            .foregroundStyle(OrbitTheme.textSecondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OrbitSettingsSkin.panelSoft)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OrbitSettingsSkin.borderSoft, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func panelCard(strong: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(strong ? OrbitSettingsSkin.panelStrong : OrbitSettingsSkin.panel)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(OrbitSettingsSkin.border, lineWidth: 1)
            }
    }

    private func auditStatus(_ row: AuditLogEntry) -> String {
        if let code = row.exit_code {
            return code == 0 ? "OK" : "ERR"
        }
        return "PENDING"
    }

    private func auditColor(_ row: AuditLogEntry) -> Color {
        if let code = row.exit_code {
            return code == 0 ? OrbitTheme.success : OrbitTheme.warning
        }
        return OrbitTheme.textTimestamp
    }
}

private struct OrganicFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrbitTheme.sans(12, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? OrbitTheme.accent.opacity(0.85) : OrbitTheme.accent)
            .clipShape(Capsule(style: .continuous))
    }
}

private struct OrganicGhostButtonStyle: ButtonStyle {
    var tint: Color = OrbitTheme.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrbitTheme.sans(11, weight: .semibold))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.75 : 1.0))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.05))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .clipShape(Capsule(style: .continuous))
    }
}
