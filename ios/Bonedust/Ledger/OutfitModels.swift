import BonedustCore
import Foundation

/// An outfit as the server describes it.
///
/// Richer than the `OutfitMembership` cached in `MetaProgress`: that one holds only what
/// the dig needs offline (the perks), while this carries the roster and the ladder, which
/// are display and need a connection anyway.
struct OutfitSnapshot: Sendable, Codable, Equatable {
    var id: String
    var name: String
    var paidTotal: Int
    var memberCount: Int
    var reachedUnlocks: [String]
    var milestones: [OutfitMilestoneState]
    var members: [OutfitMember]
    var joinCode: String?
    var yourShare: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, milestones, members
        case paidTotal = "paid_total"
        case memberCount = "member_count"
        case reachedUnlocks = "reached_unlocks"
        case joinCode = "join_code"
        case yourShare = "your_share"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The id arrives as a JSON number from Rails; a string here keeps it opaque.
        if let text = try? c.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        name = try c.decode(String.self, forKey: .name)
        paidTotal = try c.decodeIfPresent(Int.self, forKey: .paidTotal) ?? 0
        memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount) ?? 1
        reachedUnlocks = try c.decodeIfPresent([String].self, forKey: .reachedUnlocks) ?? []
        milestones = try c.decodeIfPresent([OutfitMilestoneState].self, forKey: .milestones) ?? []
        members = try c.decodeIfPresent([OutfitMember].self, forKey: .members) ?? []
        joinCode = try c.decodeIfPresent(String.self, forKey: .joinCode)
        yourShare = try c.decodeIfPresent(Double.self, forKey: .yourShare)
    }

    /// The part worth keeping on disk: enough for the outfit's perks to survive going
    /// offline, exactly as the crew's milestone unlocks do.
    var membership: OutfitMembership {
        OutfitMembership(
            id: id, name: name, paidTotal: paidTotal, memberCount: memberCount,
            reachedUnlocks: reachedUnlocks, joinCode: joinCode
        )
    }

    var nextMilestone: OutfitMilestoneState? { milestones.first { !$0.reached } }
}

struct OutfitMilestoneState: Sendable, Codable, Equatable, Identifiable {
    var key: String
    var amount: Int
    var name: String
    var beat: String?
    var unlocks: [String]
    var cosmetics: [String]
    var reached: Bool

    var id: String { key }
}

struct OutfitMember: Sendable, Codable, Equatable, Identifiable {
    var name: String
    var paidTotal: Int
    var you: Bool

    enum CodingKeys: String, CodingKey {
        case name, you
        case paidTotal = "paid_total"
    }

    var id: String { "\(name)-\(paidTotal)" }
}

struct OutfitBoardEntry: Sendable, Codable, Equatable, Identifiable {
    var rank: Int
    var name: String
    var paidTotal: Int
    var memberCount: Int
    var yours: Bool

    enum CodingKeys: String, CodingKey {
        case rank, name, yours
        case paidTotal = "paid_total"
        case memberCount = "member_count"
    }

    var id: Int { rank }
}
