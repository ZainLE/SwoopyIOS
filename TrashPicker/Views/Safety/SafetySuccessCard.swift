import SwiftUI

struct SafetySuccessCard: View {
    let message: SafetySuccessFeedback.Message
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: message.icon)
                    .font(.system(size: 64))
                    .foregroundColor(message.iconColor)

                VStack(spacing: 8) {
                    Text(message.title)
                        .font(.title2.weight(.semibold))
                        .foregroundColor(AppTheme.ColorToken.text)

                    Text(message.body)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                        .multilineTextAlignment(.center)
                }

                Button(action: onContinue) {
                    Text("Continue")
                }
                .buttonStyle(SwoopyPrimaryButtonStyle(minHeight: 50))
                .padding(.top, 4)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            )
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
    }
}
