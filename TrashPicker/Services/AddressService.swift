import Foundation
import CoreLocation
import Supabase

// What we expect the RPC to return.
struct AddressDTO: Decodable {
    let formatted: String
}

@MainActor
final class AddressService {
    static let shared = AddressService()
    private init() {}

    // Reuse the same authenticated client as the rest of the app.
    private let client = SupabaseService.shared.client

    // Strongly-typed RPC params (avoids AnyEncodable entirely).
    private struct AddressRPCParams: Encodable {
        let lat: Double
        let lon: Double
    }

    /// Ask backend to turn a coordinate into a human-readable address.
    /// Falls back to a short lat/lon string if RPC isn't ready or returns empty.
    func fetchAddress(for coord: CLLocationCoordinate2D) async -> String {
        do {
            let params = AddressRPCParams(lat: coord.latitude, lon: coord.longitude)

            let response = try await client
                .rpc("address_from_coords", params: params)
                .execute()

            let dto = try JSONDecoder().decode(AddressDTO.self, from: response.data)
            let trimmed = dto.formatted.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        } catch {
            // Optional: print("Address RPC error:", error.localizedDescription)
        }

        // Fallback until backend is ready or if it returned an empty string.
        let lat = String(format: "%.5f", coord.latitude)
        let lon = String(format: "%.5f", coord.longitude)
        return "Location near (\(lat), \(lon))"
    }
}
