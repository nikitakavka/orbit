import SwiftUI

struct OrbitUpdatePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrbitTheme.mono(9, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.84))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? OrbitTheme.accent.opacity(0.78) : OrbitTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct OrbitUpdateGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrbitTheme.mono(9, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? OrbitTheme.textSecondary : OrbitTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
