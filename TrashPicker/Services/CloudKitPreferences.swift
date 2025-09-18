//
//  CloudKitPreferences.swift
//  TrashPicker
//
//  Created by Zain Latif  on 14/9/25.
//


import Foundation
import CoreLocation

/// Only for small user prefs/drafts that benefit from iCloud KVS sync.
/// Not for posts or shared data (Supabase handles that).
final class CloudKitPreferences: ObservableObject {
    static let shared = CloudKitPreferences()
    private let store = NSUbiquitousKeyValueStore.default

    @Published var lastCity: String {
        didSet { store.set(lastCity, forKey: "lastCity"); store.synchronize() }
    }
    @Published var lastCoordinate: CLLocationCoordinate2D? {
        didSet {
            if let c = lastCoordinate {
                store.set([c.latitude, c.longitude], forKey: "lastCoord")
            } else {
                store.removeObject(forKey: "lastCoord")
            }
            store.synchronize()
        }
    }

    private init() {
        lastCity = store.string(forKey: "lastCity") ?? ""
        if let arr = store.array(forKey: "lastCoord") as? [Double], arr.count == 2 {
            lastCoordinate = .init(latitude: arr[0], longitude: arr[1])
        } else {
            lastCoordinate = nil
        }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.lastCity = store.string(forKey: "lastCity") ?? self.lastCity
            if let arr = store.array(forKey: "lastCoord") as? [Double], arr.count == 2 {
                self.lastCoordinate = .init(latitude: arr[0], longitude: arr[1])
            }
        }
    }
}