//
//  AppReviewHelper.swift
//  TrashPicker
//
//  Helper view for App Store reviewers to test safety features
//

import SwiftUI

struct AppReviewHelper: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("safety_demo_mode") private var demoMode = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 40))
                                .foregroundColor(AppTheme.ColorToken.accent)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Safety Features")
                                    .font(AppTheme.Typography.title)
                                    .foregroundColor(AppTheme.ColorToken.text)
                                
                                Text("For App Review Testing")
                                    .font(AppTheme.Typography.body)
                                    .foregroundColor(AppTheme.ColorToken.mutedGray)
                            }
                        }
                        .padding(.bottom, 8)
                        
                        Text("Swoopy includes comprehensive safety features to protect our community and comply with App Store guidelines.")
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.ColorToken.text)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    
                    Divider()
                    
                    // Demo Mode Toggle
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Demo Mode")
                            .font(AppTheme.Typography.headline)
                            .foregroundColor(AppTheme.ColorToken.text)
                        
                        Toggle(isOn: $demoMode) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Enable Demo Mode")
                                    .font(AppTheme.Typography.body)
                                
                                Text("Uses mock responses for testing without backend")
                                    .font(AppTheme.Typography.footnote)
                                    .foregroundColor(AppTheme.ColorToken.mutedGray)
                            }
                        }
                        .tint(AppTheme.ColorToken.primary)
                        
                        if demoMode {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(AppTheme.ColorToken.accent)
                                Text("Demo mode is active")
                                    .font(AppTheme.Typography.footnote)
                                    .foregroundColor(AppTheme.ColorToken.accent)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(AppTheme.ColorToken.accent.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    Divider()
                    
                    // Feature Locations
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Where to Find Safety Features")
                            .font(AppTheme.Typography.headline)
                            .foregroundColor(AppTheme.ColorToken.text)
                        
                        FeatureLocation(
                            icon: "rectangle.stack.fill",
                            title: "Feed Cards",
                            description: "Tap '•••' menu on any post card to report content or block user"
                        )
                        
                        FeatureLocation(
                            icon: "doc.text.magnifyingglass",
                            title: "Post Detail",
                            description: "Open any post, tap '•••' in top-right corner"
                        )
                        
                        FeatureLocation(
                            icon: "clock.fill",
                            title: "Reservations",
                            description: "View reservations tab, tap '•••' on counterparty posts"
                        )
                        
                        FeatureLocation(
                            icon: "bell.fill",
                            title: "Notifications",
                            description: "If applicable, tap '•••' on notification rows"
                        )
                    }
                    .padding(.horizontal, 24)
                    
                    Divider()
                    
                    // Report Categories
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Report Categories")
                            .font(AppTheme.Typography.headline)
                            .foregroundColor(AppTheme.ColorToken.text)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            CategoryItem("Spam")
                            CategoryItem("Harassment / Abuse")
                            CategoryItem("Hate / Violence")
                            CategoryItem("Fraud / Scam")
                            CategoryItem("Illegal Item / Activity")
                            CategoryItem("Inappropriate Content")
                            CategoryItem("Other")
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    Divider()
                    
                    // Response Time
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Moderation Response")
                            .font(AppTheme.Typography.headline)
                            .foregroundColor(AppTheme.ColorToken.text)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(icon: "clock", text: "Reports reviewed within 24 hours")
                            InfoRow(icon: "shield.checkmark", text: "Appropriate action taken on violations")
                            InfoRow(icon: "person.slash", text: "Users can be suspended or banned")
                            InfoRow(icon: "trash", text: "Violating content is removed")
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    Divider()
                    
                    // Contact
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Contact")
                            .font(AppTheme.Typography.headline)
                            .foregroundColor(AppTheme.ColorToken.text)
                        
                        Text("For moderation inquiries or to report issues:")
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.ColorToken.mutedGray)
                        
                        Button(action: {
                            if let url = URL(string: "mailto:support@swoopy.app") {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            HStack {
                                Image(systemName: "envelope.fill")
                                Text("support@swoopy.app")
                            }
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.ColorToken.primary)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Safety Features")
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
}

// MARK: - Supporting Views

private struct FeatureLocation: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(AppTheme.ColorToken.primary)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTheme.Typography.body.weight(.semibold))
                    .foregroundColor(AppTheme.ColorToken.text)
                
                Text(description)
                    .font(AppTheme.Typography.footnote)
                    .foregroundColor(AppTheme.ColorToken.mutedGray)
            }
        }
    }
}

private struct CategoryItem: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(AppTheme.ColorToken.accent)
            
            Text(text)
                .font(AppTheme.Typography.body)
                .foregroundColor(AppTheme.ColorToken.text)
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(AppTheme.ColorToken.primary)
                .frame(width: 24)
            
            Text(text)
                .font(AppTheme.Typography.body)
                .foregroundColor(AppTheme.ColorToken.text)
        }
    }
}

#Preview {
    AppReviewHelper()
}
