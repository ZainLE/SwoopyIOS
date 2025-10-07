//
//  LightSafariView.swift
//  TrashPicker
//
//  SwiftUI wrapper for SFSafariViewController with forced Light Mode
//

import SwiftUI
import SafariServices

struct LightSafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        // Force light appearance for OAuth/web flows
        vc.overrideUserInterfaceStyle = .light
        return vc
    }
    
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
