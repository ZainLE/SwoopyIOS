import Foundation
import LocalAuthentication

enum BiometricAuth {
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Passcode"
        
        return try await withCheckedThrowingContinuation { continuation in
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: LAError(.biometryNotAvailable))
                }
                return
            }
            
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evaluateError in
                if success {
                    continuation.resume(returning: ())
                } else if let evaluateError {
                    continuation.resume(throwing: evaluateError)
                } else {
                    continuation.resume(throwing: LAError(.authenticationFailed))
                }
            }
        }
    }
    
    static func availableBiometryType() -> LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }
}
