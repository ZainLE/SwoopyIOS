//
//  ReservationsViewModelTests.swift
//  TrashPickerTests
//
//  Tests for reservations loading and state management
//

import XCTest
@testable import Swoopy

final class ReservationsViewModelTests: XCTestCase {
    
    var mockSession: URLSession!
    var mockSupabaseService: SupabaseService!
    var apiService: ApiService!
    var viewModel: ReservationsViewModel!
    
    override func setUp() {
        super.setUp()
        mockSession = makeURLSession(using: MockURLProtocol.self)
        mockSupabaseService = SupabaseService.shared
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        viewModel = ReservationsViewModel()
    }
    
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
        mockSession = nil
        apiService = nil
        viewModel = nil
    }
    
    // MARK: - Load Reservations Tests
    
    /// Test loadReservations maps rows successfully
    func test_loadReservations_success_mapsRows() async throws {
        // Arrange: Load fixture with reservation data
        let fixtureData = try Fixtures.load("my_reservations_success")
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url?.absoluteString.contains("/my/reservations") == true)
            
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, fixtureData)
        }
        
        // Act: Load reservations
        let rows = try await viewModel.loadReservations(api: apiService)
        
        // Assert: Verify mapping
        XCTAssertEqual(rows.count, 1, "Should have 1 reservation")
        
        let row = rows[0]
        XCTAssertEqual(row.id, "R1")
        XCTAssertEqual(row.itemId, "P1")
        XCTAssertEqual(row.status, "pending")
        XCTAssertEqual(row.postTitle, "Desk")
        XCTAssertEqual(row.category, "furniture")
        XCTAssertEqual(row.mode, .home)
        
        // Verify owner data
        XCTAssertEqual(row.ownerName, "Jane Smith")
        XCTAssertEqual(row.ownerPhone, "+34987654321")
        
        print("✅ Load reservations success mapping test passed")
    }
    
    /// Test loadReservations handles error and sets showError flag
    func test_loadReservations_error_setsShowError() async throws {
        // Arrange: Stub 500 error
        MockURLProtocol.requestHandler = { request in
            let json: [String: Any] = [
                "error": "Internal server error"
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        // Act: Attempt to load reservations
        do {
            _ = try await viewModel.loadReservations(api: apiService)
            XCTFail("Should have thrown error")
        } catch {
            // Assert: Error was thrown
            XCTAssertTrue(error is ApiServiceError, "Should throw ApiServiceError")
        }
        
        print("✅ Load reservations error handling test passed")
    }
    
    /// Test loadReservations with empty response
    func test_loadReservations_emptyResponse() async throws {
        // Arrange: Stub empty reservations array
        MockURLProtocol.requestHandler = { request in
            let json: [String: Any] = [
                "reservations": []
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        // Act: Load reservations
        let rows = try await viewModel.loadReservations(api: apiService)
        
        // Assert: Should return empty array
        XCTAssertEqual(rows.count, 0, "Should have 0 reservations")
        
        print("✅ Load reservations empty response test passed")
    }
    
    // MARK: - State Management Tests
    
    /// Test maybeLoadReservations one-shot loading pattern
    func test_maybeLoadReservations_oneShot() async throws {
        // Arrange: Setup successful response
        let fixtureData = try Fixtures.load("my_reservations_success")
        
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, fixtureData)
        }
        
        // Initial state: not kicked off
        XCTAssertFalse(viewModel.didKickOff, "Should not be kicked off initially")
        XCTAssertFalse(viewModel.isLoading, "Should not be loading initially")
        XCTAssertFalse(viewModel.showError, "Should not show error initially")
        
        // Act: First call - should load
        let result1 = await viewModel.maybeLoadReservations(api: apiService)
        
        // Assert: Should have loaded
        XCTAssertTrue(result1.didLoad, "Should load on first call")
        XCTAssertTrue(viewModel.didKickOff, "Should be kicked off after first load")
        XCTAssertEqual(result1.rows.count, 1, "Should have loaded 1 reservation")
        
        // Act: Second call - should not load again
        let result2 = await viewModel.maybeLoadReservations(api: apiService)
        
        // Assert: Should not load again
        XCTAssertFalse(result2.didLoad, "Should not load on second call")
        XCTAssertTrue(viewModel.didKickOff, "Should remain kicked off")
        XCTAssertEqual(result2.rows.count, 0, "Should return empty array when not loading")
        
        print("✅ Maybe load reservations one-shot test passed")
    }
    
    /// Test state flags during loading lifecycle
    func test_stateFlags_duringLoadingLifecycle() async throws {
        // Arrange: Setup response with delay simulation
        let fixtureData = try Fixtures.load("my_reservations_success")
        
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, fixtureData)
        }
        
        // Initial state
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.showError)
        XCTAssertFalse(viewModel.didKickOff)
        
        // Start loading
        Task {
            _ = await viewModel.maybeLoadReservations(api: apiService)
        }
        
        // Give it a moment to start
        try? await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        
        // During loading (may or may not catch this due to timing)
        // After loading completes, check final state
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertFalse(viewModel.isLoading, "Should not be loading after completion")
        XCTAssertFalse(viewModel.showError, "Should not show error on success")
        XCTAssertTrue(viewModel.didKickOff, "Should be kicked off after load")
        
        print("✅ State flags during loading lifecycle test passed")
    }
    
    /// Test error state management
    func test_errorState_setsShowError() async throws {
        // Arrange: Stub error response
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        
        // Act: Attempt to load
        let result = await viewModel.maybeLoadReservations(api: apiService)
        
        // Assert: Error state set
        XCTAssertFalse(result.didLoad, "Should not have loaded successfully")
        XCTAssertTrue(viewModel.showError, "Should show error flag")
        XCTAssertFalse(viewModel.isLoading, "Should not be loading after error")
        XCTAssertTrue(viewModel.didKickOff, "Should be kicked off even on error")
        
        print("✅ Error state management test passed")
    }
    
    /// Test reset functionality
    func test_reset_clearsState() {
        // Arrange: Set some state
        viewModel.didKickOff = true
        viewModel.showError = true
        viewModel.isLoading = true
        
        // Act: Reset
        viewModel.reset()
        
        // Assert: State cleared
        XCTAssertFalse(viewModel.didKickOff, "didKickOff should be reset")
        XCTAssertFalse(viewModel.showError, "showError should be reset")
        XCTAssertFalse(viewModel.isLoading, "isLoading should be reset")
        
        print("✅ Reset clears state test passed")
    }
    
    /// Test multiple reservations mapping
    func test_loadReservations_multipleRows() async throws {
        // Arrange: Create fixture with multiple reservations
        let json: [String: Any] = [
            "reservations": [
                [
                    "id": "R1",
                    "item_id": "P1",
                    "reserver": "user-123",
                    "status": "pending",
                    "requested_at": "2024-01-01T00:00:00Z",
                    "approved_at": nil,
                    "start_at": nil,
                    "end_at": nil,
                    "picked_up_at": nil,
                    "canceled_at": nil,
                    "post": [
                        "id": "P1",
                        "title": "Desk",
                        "description": nil,
                        "category": "furniture",
                        "condition": "excellent",
                        "mode": "street",
                        "owner_id": "owner-1",
                        "created_at": "2024-01-01T00:00:00Z",
                        "expires_at": "2024-01-02T00:00:00Z",
                        "exact_location": ["lng": "2.1686", "lat": "41.3874"],
                        "approx_location": nil,
                        "images": [],
                        "distance": nil,
                        "owner": nil,
                        "user_reservation": nil
                    ]
                ],
                [
                    "id": "R2",
                    "item_id": "P2",
                    "reserver": "user-123",
                    "status": "approved",
                    "requested_at": "2024-01-02T00:00:00Z",
                    "approved_at": "2024-01-02T01:00:00Z",
                    "start_at": nil,
                    "end_at": nil,
                    "picked_up_at": nil,
                    "canceled_at": nil,
                    "post": [
                        "id": "P2",
                        "title": "Chair",
                        "description": nil,
                        "category": "furniture",
                        "condition": "good",
                        "mode": "home",
                        "owner_id": "owner-2",
                        "created_at": "2024-01-02T00:00:00Z",
                        "expires_at": "2024-01-03T00:00:00Z",
                        "exact_location": nil,
                        "approx_location": ["lng": "2.1700", "lat": "41.3900"],
                        "images": [],
                        "distance": nil,
                        "owner": nil,
                        "user_reservation": nil
                    ]
                ]
            ]
        ]
        
        let data = try! JSONSerialization.data(withJSONObject: json)
        
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        
        // Act: Load reservations
        let rows = try await viewModel.loadReservations(api: apiService)
        
        // Assert: Both reservations mapped
        XCTAssertEqual(rows.count, 2, "Should have 2 reservations")
        XCTAssertEqual(rows[0].id, "R1")
        XCTAssertEqual(rows[0].status, "pending")
        XCTAssertEqual(rows[1].id, "R2")
        XCTAssertEqual(rows[1].status, "approved")
        
        print("✅ Multiple reservations mapping test passed")
    }
}

// MARK: - Reservations View Model

/// Testable view model for reservations loading and state management
class ReservationsViewModel {
    // State flags
    var isLoading: Bool = false
    var showError: Bool = false
    var didKickOff: Bool = false
    
    /// Result of attempting to load reservations
    struct LoadResult {
        let didLoad: Bool
        let rows: [ReservationRow]
    }
    
    /// Load reservations from API (pure mapping)
    /// - Parameter api: ApiService instance
    /// - Returns: Array of ReservationRow
    func loadReservations(api: ApiService) async throws -> [ReservationRow] {
        let reservations = try await api.getMyReservations()
        return reservations.map { ReservationRow($0) }
    }
    
    /// Maybe load reservations (one-shot pattern)
    /// - Parameter api: ApiService instance
    /// - Returns: LoadResult with didLoad flag and rows
    func maybeLoadReservations(api: ApiService) async -> LoadResult {
        // Only load if not already kicked off
        guard !didKickOff else {
            return LoadResult(didLoad: false, rows: [])
        }
        
        // Mark as kicked off
        didKickOff = true
        isLoading = true
        showError = false
        
        do {
            let rows = try await loadReservations(api: api)
            isLoading = false
            return LoadResult(didLoad: true, rows: rows)
        } catch {
            isLoading = false
            showError = true
            return LoadResult(didLoad: false, rows: [])
        }
    }
    
    /// Reset state (e.g., after logout or manual refresh)
    func reset() {
        didKickOff = false
        showError = false
        isLoading = false
    }
}
