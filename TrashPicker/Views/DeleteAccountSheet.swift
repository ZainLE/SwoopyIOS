import SwiftUI

struct DeleteAccountSheet: View {
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let confirmIconName: String
    let cornerRadius: CGFloat
    let isDeleting: Bool
    let canConfirm: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete your account?")
                    .font(AppFont.h3)
                    .foregroundColor(AppColor.text)
                Text(message)
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)
            }
            
            Button(action: onConfirm) {
                HStack(spacing: 12) {
                    if isDeleting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: confirmIconName)
                            .font(.system(size: 18, weight: .semibold))
                        Text(confirmTitle)
                            .font(AppFont.body.weight(.semibold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.ColorToken.danger)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .opacity((canConfirm && !isDeleting) ? 1.0 : 0.55)
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm || isDeleting)
            .accessibilityLabel(confirmTitle)
            
            Button(action: onCancel) {
                Text(cancelTitle)
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(AppColor.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.2), radius: 20, y: 10)
    }
}
