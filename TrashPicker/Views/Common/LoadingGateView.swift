import SwiftUI

struct LoadingGateView: View {
    var message: String?
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}
