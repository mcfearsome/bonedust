import BonedustCore
import GameKit
import SwiftUI

/// Game Center, kept at arm's length (§5).
///
/// Every call here fails soft. A player who is not signed in, who is offline, or who is
/// in a country where Game Center is unavailable must get exactly the same game as
/// anyone else — so nothing in the dig loop ever waits on this, checks its result, or
/// branches on whether it worked.
///
/// Gentle mode is enforced at this boundary rather than at the call sites: §7 says those
/// runs do not appear on leaderboards, and a single gate is harder to forget than six.
@MainActor
@Observable
final class GameCenterService {

    private(set) var isAuthenticated = false
    /// The player's Game Center alias, when there is one. Used as the opt-in display
    /// name for the crew ledger (M5) and for nothing else.
    private(set) var alias: String?

    /// Set false for Gentle mode runs.
    var isEligibleForLeaderboards = true

    private var hasRequestedAuthentication = false

    func authenticate() {
        guard !hasRequestedAuthentication else { return }
        hasRequestedAuthentication = true
        GKLocalPlayer.local.authenticateHandler = { [weak self] _, _ in
            // The view controller argument is deliberately ignored: Game Center's sign-in
            // sheet is not worth interrupting someone who opened the app to dig.
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticated = GKLocalPlayer.local.isAuthenticated
                self.alias = GKLocalPlayer.local.isAuthenticated
                    ? GKLocalPlayer.local.alias
                    : nil
            }
        }
    }

    // MARK: Leaderboards

    func submit(_ meta: MetaProgress) {
        guard isAuthenticated, isEligibleForLeaderboards else { return }
        submit(meta.longestStreak, to: Leaderboard.runStreak)
        submit(meta.bestSlabPayout, to: Leaderboard.bestSlab)
        submit(meta.lifetimeContribution, to: Leaderboard.crewContribution)
    }

    private func submit(_ score: Int, to leaderboardID: String) {
        guard score > 0 else { return }
        GKLeaderboard.submitScore(
            score, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [leaderboardID]
        ) { _ in
            // Nothing to do on failure. The authoritative numbers live in the save file
            // and the crew ledger; Game Center is a mirror, not a record.
        }
    }

    // MARK: Achievements

    /// Reports achievements as complete. Takes ids from the content catalog so the
    /// Game Center identifier can be corrected in data if App Store Connect disagrees.
    func report(achievementIDs: [String], catalog: ContentCatalog = .shared) {
        guard isAuthenticated, !achievementIDs.isEmpty else { return }
        let achievements = achievementIDs
            .compactMap { catalog.achievement($0) }
            .map { definition -> GKAchievement in
                let achievement = GKAchievement(identifier: definition.gameCenterID)
                achievement.percentComplete = 100
                achievement.showsCompletionBanner = true
                return achievement
            }
        guard !achievements.isEmpty else { return }
        GKAchievement.report(achievements) { _ in }
    }

    /// Everything a finished run produced, in one call.
    func record(_ meta: MetaProgress, rewards: MetaProgress.Rewards, gentleMode: Bool) {
        isEligibleForLeaderboards = !gentleMode
        submit(meta)
        // Achievements are reported even in Gentle mode: §7 excludes those runs from
        // leaderboards, which are competitive, not from achievements, which are not.
        report(achievementIDs: rewards.newAchievements)
    }
}
