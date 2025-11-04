import Foundation
import AuthenticationServices
import CryptoKit
import Supabase
import SwiftUI
import UIKit

// MARK: - Nonce helpers
func randomNonceString(length: Int = 32) -> String {
    precondition(length > 0)
    let charset: [Character] =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    var result = ""
    var remainingLength = length

    while remainingLength > 0 {
        var randoms = [UInt8](repeating: 0, count: 16)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
        if errorCode != errSecSuccess { fatalError("Unable to generate nonce. OSStatus \(errorCode)") }
        randoms.forEach { random in
            if remainingLength == 0 { return }
            if random < charset.count {
                result.append(charset[Int(random)])
                remainingLength -= 1
            }
        }
    }
    return result
}

func sha256(_ input: String) -> String {
    let inputData = Data(input.utf8)
    let hashed = SHA256.hash(data: inputData)
    return hashed.compactMap { String(format: "%02x", $0) }.joined()
}

// MARK: - JWT payload debug (base64url decode)
func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var base64 = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let pad = 4 - base64.count % 4
    if pad < 4 { base64 += String(repeating: "=", count: pad) }
    guard let data = Data(base64Encoded: base64),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}

// MARK: - Apple Sign In Coordinator
@MainActor
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let supabase: SupabaseClient
    private let onSuccess: (Session) -> Void
    private let onError: (Error) -> Void
    private var currentRawNonce: String?
    private var controller: ASAuthorizationController?
    
    private func cleanup() {
        controller = nil
        currentRawNonce = nil
    }

    init(
        supabase: SupabaseClient,
        onSuccess: @escaping (Session) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.supabase = supabase
        self.onSuccess = onSuccess
        self.onError = onError
    }

    func start() {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let rawNonce = randomNonceString()
        currentRawNonce = rawNonce
        request.nonce = sha256(rawNonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        controller.performRequests()
        DLog("🍎 Apple Sign-In START | nonce(raw)=\(rawNonce)")
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let rawNonce = currentRawNonce
        else {
            let error = NSError(domain: "AppleAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing token or nonce"])
            DLog("❌ Apple Sign-In ERROR | \(error.localizedDescription)")
            onError(error)
            cleanup()
            return
        }

        if let payload = decodeJWTPayload(idToken) {
            let aud = payload["aud"] ?? "nil"
            let nonce = payload["nonce"] ?? "nil"
            let iss = payload["iss"] ?? "nil"
            let exp = payload["exp"] ?? "nil"
            let sub = payload["sub"] ?? "nil"
            DLog("🍎 Apple payload | aud=\(aud) nonce=\(nonce) iss=\(iss) exp=\(exp) sub=\(sub)")
        } else {
            DLog("⚠️ Apple payload decode failed")
        }

        Task { @MainActor in
            do {
                DLog("🍎 Exchanging Apple credential with Supabase…")
                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(
                        provider: .apple,
                        idToken: idToken,
                        nonce: rawNonce
                    )
                )
                DLog("✅ Apple Sign-In SUCCESS | userId: \(session.user.id.uuidString)")
                onSuccess(session)
                cleanup()
            } catch {
                DLog("❌ Apple Sign-In FAILED | \(error)")
                onError(error)
                cleanup()
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        DLog("❌ Apple Sign-In ERROR | \(error)")
        onError(error)
        cleanup()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
