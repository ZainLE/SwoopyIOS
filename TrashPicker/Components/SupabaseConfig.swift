//
//  SupabaseConfig.swift
//  TrashPicker
//
//  Created by Zain Latif  on 14/9/25.
//


import Foundation

/// Fill these from your Supabase project's Settings → API.
enum SupabaseConfig {
    // Example: "https://abcxyz.supabase.co"
    static let url = URL(string: "https://scwpewxsidnpfnymibek.supabase.co")!

    // Your anon public key (safe to ship in client)
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNjd3Bld3hzaWRucGZueW1pYmVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc4ODk2MzUsImV4cCI6MjA3MzQ2NTYzNX0.U_FjyvC8rqe2S13TU4bn3Gmbi6IJVJf3LMwfv04onr8"

    // Storage bucket name to hold post photos (create it in Supabase Storage)
    static let photosBucket = "item-photos"

    // Table names
    static let postsTable = "posts"
}
