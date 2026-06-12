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
                SwoopyToast(
                    message: text,
                    style: toastCenter.isError ? .error : .success,
                    onTap: { toastCenter.dismiss() }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 100) // Above tab bar
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toastCenter.text)
    }
}
