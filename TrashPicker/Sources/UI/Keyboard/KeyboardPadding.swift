import SwiftUI
import Combine

#if canImport(UIKit)
private final class KeyboardObserver: ObservableObject {
    @Published var bottomInset: CGFloat = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let willChange = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)

        Publishers.Merge(willChange, willHide)
            .sink { [weak self] notification in
                guard let self else { return }
                guard let userInfo = notification.userInfo else { return }
                let animationDuration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
                let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                let safeInset = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first(where: { $0.isKeyWindow })?
                    .safeAreaInsets.bottom ?? 0
                let height = max(0, endFrame.height - safeInset)

                withAnimation(.easeOut(duration: animationDuration)) {
                    self.bottomInset = height
                }
            }
            .store(in: &cancellables)
    }
}
#endif

private struct KeyboardPaddingModifier: ViewModifier {
    #if canImport(UIKit)
    @StateObject private var observer = KeyboardObserver()
    #endif

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content
            .padding(.bottom, observer.bottomInset)
        #else
        content
        #endif
    }
}

extension View {
    func keyboardPadding() -> some View {
        modifier(KeyboardPaddingModifier())
    }
}
