//
//  SafetySettingsSection.swift
//  TrashPicker
//
//  Safety settings section for Profile/Settings view
//

import SwiftUI

struct SafetySettingsSection: View {
    @AppStorage("feature_safety_v1") private var featureSafety = true
    @ObservedObject private var hiddenStore = HiddenContentStore.shared
    
    var body: some View {
        Section {
            // Feature flag toggle
            Toggle(isOn: $featureSafety) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safety Features")
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.text)
                    
                    Text("Report content and block users")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                }
            }
            .tint(AppTheme.ColorToken.primary)

            Toggle(isOn: $hiddenStore.hideReportedContent) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hide reported content")
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.text)
                    
                    Text("Filter posts you have reported")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                }
            }
            .tint(AppTheme.ColorToken.primary)
            
        } header: {
            Text("Safety & Moderation")
                .font(AppTheme.Typography.headline)
        }
    }
}

// Standalone view for testing/preview
struct SafetySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            SafetySettingsSection()
            
            Section {
                SafetyChecklistRow(
                    icon: "eye.slash",
                    title: "Filter objectionable content",
                    detail: "Posts you report are hidden from your feed and reservations while our team reviews them."
                )
                
                SafetyChecklistRow(
                    icon: "flag.fill",
                    title: "Flag abusive posts",
                    detail: "Click on Make a report to report a post and let us know."
                )
                
                SafetyChecklistRow(
                    icon: "hand.raised.fill",
                    title: "Block abusive users",
                    detail: "Block from the same menu to remove their posts and prevent them from contacting you."
                )
                
                SafetyChecklistRow(
                    icon: "clock.badge.checkmark",
                    title: "24h moderation response",
                    detail: "We review every report, remove violating content, and suspend offending accounts within 24 hours."
                )
            } header: {
                Text("Moderation Coverage")
                    .font(AppTheme.Typography.headline)
            }
            
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundColor(AppTheme.ColorToken.primary)
                    Text("contact@swoopy.eu")
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                }
                Text("Reports and blocks help keep Swoopy safe for everyone.")
                    .font(AppTheme.Typography.footnote)
                    .foregroundColor(AppTheme.ColorToken.mutedGray)
                    .padding(.top, 2)
            } header: {
                Text("Support")
                    .font(AppTheme.Typography.headline)
            }
        }
        .navigationTitle("Safety & Moderation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
                .foregroundColor(AppTheme.ColorToken.primary)
            }
        }
    }
}

private struct SafetyChecklistRow: View {
    let icon: String
    let title: String
    let detail: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(AppTheme.ColorToken.primary)
                .frame(width: 22)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTheme.Typography.body.weight(.semibold))
                    .foregroundColor(AppTheme.ColorToken.text)
                
                Text(detail)
                    .font(AppTheme.Typography.footnote)
                    .foregroundColor(AppTheme.ColorToken.mutedGray)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        SafetySettingsView()
    }
}
