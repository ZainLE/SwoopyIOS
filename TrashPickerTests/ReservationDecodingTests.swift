//
//  ReservationDecodingTests.swift
//  TrashPickerTests
//
//  Tests for Reservation model decoding from backend API
//

import XCTest
@testable import Swoopy

final class ReservationDecodingTests: XCTestCase {
    
    /// Test decoding a sample /my/reservations response from the backend
    /// This verifies the CodingKeys mapping is correct (post vs posts)
    func testReservationDecoding() throws {
        // Sample JSON matching backend /my/reservations response format
        let json = """
        {
            "reservations": [
                {
                    "id": "res-123",
                    "item_id": "post-456",
                    "reserver": "user-789",
                    "status": "active",
                    "requested_at": "2024-01-15T10:30:00Z",
                    "approved_at": "2024-01-15T11:00:00Z",
                    "start_at": "2024-01-15T11:00:00Z",
                    "end_at": "2024-01-15T17:00:00Z",
                    "picked_up_at": null,
                    "canceled_at": null,
                    "post": {
                        "id": "post-456",
                        "title": "Vintage Chair",
                        "description": "A nice wooden chair",
                        "category": "furniture",
                        "condition": "good",
                        "mode": "street",
                        "owner_id": "owner-123",
                        "created_at": "2024-01-15T09:00:00Z",
                        "expires_at": "2024-01-16T09:00:00Z",
                        "exact_location": {
                            "lng": "2.1686",
                            "lat": "41.3874"
                        },
                        "approx_location": null,
                        "images": [
                            {
                                "url": "https://example.com/image.jpg",
                                "order_index": 0
                            }
                        ],
                        "distance": 1.5,
                        "owner": {
                            "id": "owner-123",
                            "first_name": "John",
                            "last_name": "Doe",
                            "city": "Barcelona",
                            "avatar_url": null,
                            "given_count": 5,
                            "picked_count": 3,
                            "phone": "+34123456789"
                        },
                        "user_reservation": null
                    }
                }
            ]
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // This should decode successfully if CodingKeys are correct
        struct ReservationsResponse: Codable {
            let reservations: [Reservation]
        }
        
        XCTAssertNoThrow(try decoder.decode(ReservationsResponse.self, from: data), 
                        "Should decode reservations response without error")
        
        let response = try decoder.decode(ReservationsResponse.self, from: data)
        
        // Verify structure
        XCTAssertEqual(response.reservations.count, 1, "Should have 1 reservation")
        
        let reservation = response.reservations[0]
        XCTAssertEqual(reservation.id, "res-123")
        XCTAssertEqual(reservation.itemId, "post-456")
        XCTAssertEqual(reservation.status, "active")
        
        // Verify nested post object decoded correctly
        XCTAssertEqual(reservation.post.id, "post-456")
        XCTAssertEqual(reservation.post.title, "Vintage Chair")
        XCTAssertEqual(reservation.post.condition, .good)
        XCTAssertEqual(reservation.post.mode, .street)
        
        // Verify owner data
        XCTAssertNotNil(reservation.post.owner)
        XCTAssertEqual(reservation.post.owner?.firstName, "John")
        XCTAssertEqual(reservation.post.owner?.lastName, "Doe")
        XCTAssertEqual(reservation.post.owner?.phone, "+34123456789")
        
        print("✅ Reservation decoding test passed - CodingKeys are correct")
    }
    
    /// Test that the old incorrect key "posts" would fail
    func testIncorrectKeyFails() throws {
        // JSON with incorrect key "posts" instead of "post"
        let incorrectJson = """
        {
            "reservations": [
                {
                    "id": "res-123",
                    "item_id": "post-456",
                    "reserver": "user-789",
                    "status": "active",
                    "requested_at": "2024-01-15T10:30:00Z",
                    "approved_at": null,
                    "start_at": null,
                    "end_at": null,
                    "picked_up_at": null,
                    "canceled_at": null,
                    "posts": {
                        "id": "post-456",
                        "title": "Test",
                        "description": null,
                        "category": "furniture",
                        "condition": "good",
                        "mode": "street",
                        "owner_id": "owner-123",
                        "created_at": "2024-01-15T09:00:00Z",
                        "expires_at": "2024-01-16T09:00:00Z",
                        "exact_location": null,
                        "approx_location": null,
                        "images": [],
                        "distance": null,
                        "owner": null,
                        "user_reservation": null
                    }
                }
            ]
        }
        """
        
        let data = incorrectJson.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        struct ReservationsResponse: Codable {
            let reservations: [Reservation]
        }
        
        // This should fail because the key is "posts" but we expect "post"
        XCTAssertThrowsError(try decoder.decode(ReservationsResponse.self, from: data),
                            "Should fail when backend uses 'posts' key instead of 'post'")
        
        print("✅ Incorrect key test passed - properly rejects 'posts' key")
    }
}
