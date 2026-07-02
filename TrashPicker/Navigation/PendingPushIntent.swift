import Foundation

struct PendingPushIntent: Codable, Equatable {
    static let defaultTTL: TimeInterval = 60 * 30

    enum Source: String, Codable {
        case push
        case inApp
    }

    let notificationId: UUID?
    let reservationId: UUID?
    let postId: UUID?
    let receivedAt: Date
    let expiresAt: Date
    let source: Source
    let intentType: String?

    static func from(additionalData: [AnyHashable: Any], source: Source = .push) -> PendingPushIntent? {
        let notificationId = parseUUID(additionalData["notification_id"])
        let reservationId = parseUUID(additionalData["reservation_id"])
        let postId = parseUUID(additionalData["post_id"])
        let intentType = parseString(additionalData["push_intent"]) ?? parseString(additionalData["type"])

        // Some pushes carry no ids — the type alone is routable.
        let isTypeOnlyIntent: Bool = {
            guard let type = intentType?.lowercased() else { return false }
            return type.hasPrefix("collection_night")
                || type == "leaderboard_week_result"
                || type == "badge_earned"
        }()

        guard notificationId != nil || reservationId != nil || postId != nil || isTypeOnlyIntent else {
            return nil
        }

        let receivedAt = Date()
        return PendingPushIntent(
            notificationId: notificationId,
            reservationId: reservationId,
            postId: postId,
            receivedAt: receivedAt,
            expiresAt: receivedAt.addingTimeInterval(defaultTTL),
            source: source,
            intentType: intentType
        )
    }

    var debugSummary: String {
        "notificationId=\(notificationId?.uuidString ?? "nil") reservationId=\(reservationId?.uuidString ?? "nil") postId=\(postId?.uuidString ?? "nil") type=\(intentType ?? "nil") source=\(source.rawValue) receivedAt=\(receivedAt) expiresAt=\(expiresAt)"
    }

    enum CodingKeys: String, CodingKey {
        case notificationId
        case reservationId
        case postId
        case receivedAt
        case expiresAt
        case source
        case intentType
    }

    init(notificationId: UUID?, reservationId: UUID?, postId: UUID?, receivedAt: Date, expiresAt: Date, source: Source, intentType: String?) {
        self.notificationId = notificationId
        self.reservationId = reservationId
        self.postId = postId
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
        self.source = source
        self.intentType = intentType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let notificationId = try container.decodeIfPresent(UUID.self, forKey: .notificationId)
        let reservationId = try container.decodeIfPresent(UUID.self, forKey: .reservationId)
        let postId = try container.decodeIfPresent(UUID.self, forKey: .postId)
        let receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        let expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt) ?? receivedAt.addingTimeInterval(Self.defaultTTL)
        let source = try container.decode(Source.self, forKey: .source)
        let intentType = try container.decodeIfPresent(String.self, forKey: .intentType)

        self.init(
            notificationId: notificationId,
            reservationId: reservationId,
            postId: postId,
            receivedAt: receivedAt,
            expiresAt: expiresAt,
            source: source,
            intentType: intentType
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(notificationId, forKey: .notificationId)
        try container.encodeIfPresent(reservationId, forKey: .reservationId)
        try container.encodeIfPresent(postId, forKey: .postId)
        try container.encode(receivedAt, forKey: .receivedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(intentType, forKey: .intentType)
    }

    private static func parseUUID(_ value: Any?) -> UUID? {
        if let uuid = value as? UUID {
            return uuid
        }
        if let string = value as? String {
            return UUID(uuidString: string)
        }
        if let number = value as? NSNumber {
            return UUID(uuidString: number.stringValue)
        }
        return nil
    }

    private static func parseString(_ value: Any?) -> String? {
        if let string = value as? String, string.isEmpty == false {
            return string
        }
        return nil
    }
}
