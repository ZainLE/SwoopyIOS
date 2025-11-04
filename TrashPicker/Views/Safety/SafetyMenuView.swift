//
//  SafetyMenuView.swift
//  TrashPicker
//
//  Reusable safety menu for feed cards and detail views
//

import SwiftUI

struct SafetyMenuView: View {
    @EnvironmentObject var api: ApiService
    @AppStorage("feature_safety_v1") private var featureSafety = true
    
    let postId: String?
    let userId: String?
    let userName: String?
    
    @State private var showReportSheet = false
    @State private var showBlockSheet = false
    
    var body: some View {
        if featureSafety {
            Menu {
                Button(action: {
                    DLog("[SAFETY] report_open post=\(postId ?? "nil") user=\(userId ?? "nil")")
                    showReportSheet = true
                    Haptics.play(.tabSelect)
                }) {
                    Label(SafetyStrings.report, systemImage: "flag")
                }
                .foregroundStyle(.red)
                
                if userId != nil {
                    Button(action: {
                        DLog("[SAFETY] block_open user=\(userId ?? "nil")")
                        showBlockSheet = true
                        Haptics.play(.tabSelect)
                    }) {
                        Label(SafetyStrings.blockUser, systemImage: "hand.raised")
                    }
                    .foregroundStyle(.red)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AppTheme.ColorToken.text)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            }
            .accessibilityLabel("More options")
            .sheet(isPresented: $showReportSheet) {
                ReportSheet(
                    targetPostId: postId,
                    targetUserId: userId
                )
                .environmentObject(api)
            }
            .sheet(isPresented: $showBlockSheet) {
                if let userId = userId {
                    BlockUserSheet(
                        userId: userId,
                        userName: userName
                    )
                    .environmentObject(api)
                }
            }
        }
    }
}

// Compact version for inline use (no background circle)
struct SafetyMenuCompact: View {
    @EnvironmentObject var api: ApiService
    @AppStorage("feature_safety_v1") private var featureSafety = true
    
    let postId: String?
    let userId: String?
    let userName: String?
    
    @State private var showReportSheet = false
    @State private var showBlockSheet = false
    
    var body: some View {
        if featureSafety {
            Menu {
                Button(action: {
                    DLog("[SAFETY] report_open post=\(postId ?? "nil") user=\(userId ?? "nil")")
                    showReportSheet = true
                    Haptics.play(.tabSelect)
                }) {
                    Label(SafetyStrings.report, systemImage: "flag")
                }
                
                if userId != nil {
                    Button(action: {
                        DLog("[SAFETY] block_open user=\(userId ?? "nil")")
                        showBlockSheet = true
                        Haptics.play(.tabSelect)
                    }) {
                        Label(SafetyStrings.blockUser, systemImage: "hand.raised")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(AppTheme.ColorToken.mutedGray)
            }
            .accessibilityLabel("More options")
            .sheet(isPresented: $showReportSheet) {
                ReportSheet(
                    targetPostId: postId,
                    targetUserId: userId
                )
                .environmentObject(api)
            }
            .sheet(isPresented: $showBlockSheet) {
                if let userId = userId {
                    BlockUserSheet(
                        userId: userId,
                        userName: userName
                    )
                    .environmentObject(api)
                }
            }
        }
    }
}
