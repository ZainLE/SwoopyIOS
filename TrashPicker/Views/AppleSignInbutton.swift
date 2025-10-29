//
//  AppleSignInbutton.swift
//  TrashPicker
//
//  Created by Zain Latif  on 19/9/25.
//


import SwiftUI
import AuthenticationServices

struct AppleSignInButton: View {
    var type: ASAuthorizationAppleIDButton.ButtonType = .signIn
    var style: ASAuthorizationAppleIDButton.Style = .black
    var action: () -> Void

    var body: some View {
        _AppleButtonRepresentable(type: type, style: style, action: action)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct _AppleButtonRepresentable: UIViewRepresentable {
    let type: ASAuthorizationAppleIDButton.ButtonType
    let style: ASAuthorizationAppleIDButton.Style
    let action: () -> Void

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let b = ASAuthorizationAppleIDButton(type: type, style: style)
        b.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return b
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}

