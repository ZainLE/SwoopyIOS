//
//  TrashPickerApp.swift
//  TrashPicker
//
//  Created by Zain Latif  on 3/9/25.
//

import SwiftUI

@main
struct TrashPickerApp: App {
    @StateObject private var ck = CKTrashService.shared
    @StateObject private var loc = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ck)
                .environmentObject(loc)
        }
    }
}
