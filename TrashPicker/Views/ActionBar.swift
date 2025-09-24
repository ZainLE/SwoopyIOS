//
//  ActionBar.swift
//  TrashPicker
//
//  Independent action bar that persists outside the card stack
//

import SwiftUI

struct ActionBar: View {
    @ObservedObject var deckState: DeckState
    let onPass: () -> Void
    let onReserve: () -> Void
    
    // Design tokens
    private let primary = Color(hex: "#00513F")      // #00513F
    private let chromeSidePadding: CGFloat = 16     // Match tab bar content padding
    private let buttonRadius: CGFloat = 59
    
    // Dimensions
    private var screenWidth: CGFloat {
        UIScreen.main.bounds.width
    }
    private var barWidth: CGFloat {
        screenWidth - (chromeSidePadding * 2) // Match card width
    }
    
    var body: some View {
        if deckState.hasCards {
            HStack(spacing: 16) {
                // Pass button
                Button(action: onPass) {
                    HStack {
                        if deckState.isActing {
                            ProgressView()
                                .scaleEffect(0.8)
                                .foregroundColor(.black)
                        }
                        Text("Pass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                    }
                    .frame(height: 56)
                    .frame(maxWidth: .infinity)
                }
                .disabled(!deckState.canAct)
                .background(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: buttonRadius, style: .continuous)
                        .stroke(primary, lineWidth: 3)
                        .opacity(deckState.canAct ? 1.0 : 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
                .accessibilityLabel("Pass on this item")
                
                // Save for Me button
                Button(action: onReserve) {
                    HStack {
                        if deckState.isActing {
                            ProgressView()
                                .scaleEffect(0.8)
                                .foregroundColor(.white)
                        }
                        Text("Save for Me")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(height: 56)
                    .frame(maxWidth: .infinity)
                }
                .disabled(!deckState.canAct)
                .background(primary.opacity(deckState.canAct ? 1.0 : 0.5))
                .clipShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
                .accessibilityLabel("Save this item for me")
            }
            .padding(.horizontal, chromeSidePadding)
            .animation(.easeInOut(duration: 0.2), value: deckState.canAct)
        }
    }
}

