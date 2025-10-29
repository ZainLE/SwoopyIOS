import SwiftUI
import Combine

final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    
    @Published var text: String? = nil
    @Published var isError: Bool = false
    
    private var dismissTask: Task<Void, Never>?
    
    private init() {}
    
    func show(_ message: String, isError: Bool = false) {
        dismissTask?.cancel()
        
        Task { @MainActor in
            self.text = message
            self.isError = isError
            
            dismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                if !Task.isCancelled {
                    self.text = nil
                    self.isError = false
                }
            }
        }
    }
    
    func dismiss() {
        dismissTask?.cancel()
        text = nil
        isError = false
    }
}

// MARK: - Toast View

struct ToastView: View {
    @ObservedObject var toastCenter: ToastCenter
    
    var body: some View {
        VStack {
            Spacer()
            
            if let text = toastCenter.text {
                HStack(spacing: 12) {
                    Image(systemName: toastCenter.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(toastCenter.isError ? .red : AppTheme.ColorToken.accent)
                    
                    Text(text)
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.text)
                        .multilineTextAlignment(.leading)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 100) // Above tab bar
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture {
                    toastCenter.dismiss()
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toastCenter.text)
    }
}
