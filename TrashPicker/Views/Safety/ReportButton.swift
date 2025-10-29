//
//  ReportButton.swift
//  TrashPicker
//
//  Compact report button for menus
//

import SwiftUI

struct ReportButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Label(SafetyStrings.report, systemImage: "flag")
                .labelStyle(.titleAndIcon)
        }
        .foregroundStyle(.red)
        .accessibilityLabel(SafetyStrings.report)
        .accessibilityHint("Report this content for review")
    }
}

struct BlockUserButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Label(SafetyStrings.blockUser, systemImage: "hand.raised")
                .labelStyle(.titleAndIcon)
        }
        .foregroundStyle(.red)
        .accessibilityLabel(SafetyStrings.blockUser)
        .accessibilityHint("Block this user from contacting you")
    }
}
