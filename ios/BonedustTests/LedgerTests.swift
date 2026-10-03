import BonedustCore
import XCTest
@testable import Bonedust

@MainActor
final class PaymentQueueTests: XCTestCase {

    /// A client pointed at nothing, so `submit` always fails the way being offline does.
    private func offlineClient() -> LedgerClient {
        LedgerClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            installID: UUID().uuidString,
            attestation: LedgerAttestation(
                defaults: UserDefaults(suiteName: "bonedust.q.\(UUID().uuidString)")!
            )
        )
    }

    private func makeQueue() -> PaymentQueue {
        PaymentQueue(
            client: offlineClient(),
            storeURL: URL.temporaryDirectory.appending(path: "queue-\(UUID().uuidString).json")
        )
    }

    private func record(seed: UInt64 = 1, total: Int = 90) -> SlabRecord {
        SlabRecord(
            day: 1, seed: seed, siteID: "charmouth", fossilID: "ammonite",
            payout: PayoutBreakdown(
                baseValue: 90, exposure: 0.9, intact: 1, fossil: total, gems: 0,
                bonuses: 0, multiplier: 1, rushApplied: false, total: total
            ),
            durationMillis: 42_000, bagged: true, wholeGems: 0, daylightLeft: 8,
            identified: true
        )
    }

    func testEnqueueKeepsAPaymentAndTotalsIt() {
        let queue = makeQueue()
        queue.enqueue(record: record(total: 90), charmIDs: [], serverSlabID: "abc", localSeed: nil)
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertEqual(queue.pendingTotal, 90)
        XCTAssertEqual(queue.pending.first?.slabID, "abc")
    }

    func testTheSameSlabIsNeverQueuedTwice() {
        let queue = makeQueue()
        queue.enqueue(record: record(), charmIDs: [], serverSlabID: "abc", localSeed: nil)
        queue.enqueue(record: record(), charmIDs: [], serverSlabID: "abc", localSeed: nil)
        XCTAssertEqual(queue.pending.count, 1, "a duplicate would double-count the debt")
    }

    func testAnOfflineSlabCarriesItsSeedSoTheServerCanCheckIt() {
        let queue = makeQueue()
        queue.enqueue(record: record(seed: 4242), charmIDs: [], serverSlabID: nil, localSeed: 4242)
        guard let payment = queue.pending.first else { return XCTFail() }
        XCTAssertEqual(payment.localSeed, 4242)
        XCTAssertTrue(payment.slabID.hasPrefix("local-"))
        // A seed past 2^53 has to go over the wire as a string.
        XCTAssertEqual(payment.wireFormat["seed"], .string("4242"))
    }

    func testAServerIssuedSlabSendsNoSeed() {
        let queue = makeQueue()
        queue.enqueue(record: record(), charmIDs: [], serverSlabID: "abc", localSeed: 999)
        XCTAssertNil(queue.pending.first?.localSeed)
        XCTAssertNil(queue.pending.first?.wireFormat["seed"])
    }

    func testTheQueueSurvivesBeingReloaded() {
        let url = URL.temporaryDirectory.appending(path: "queue-\(UUID().uuidString).json")
        let first = PaymentQueue(client: offlineClient(), storeURL: url)
        first.enqueue(record: record(total: 120), charmIDs: ["rush_job"],
                      serverSlabID: "xyz", localSeed: nil)

        let reloaded = PaymentQueue(client: offlineClient(), storeURL: url)
        XCTAssertEqual(reloaded.pending.count, 1, "a killed app lost a payment")
        XCTAssertEqual(reloaded.pendingTotal, 120)
        XCTAssertEqual(reloaded.pending.first?.charmIDs, ["rush_job"])
    }

    func testFlushingWhileOfflineKeepsEverything() async {
        let queue = makeQueue()
        queue.enqueue(record: record(), charmIDs: [], serverSlabID: "abc", localSeed: nil)
        let sent = await queue.flush()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(queue.pending.count, 1, "an unreachable server must not lose a payment")
        XCTAssertEqual(queue.pending.first?.attempts, 1)
    }

    func testAnEmptyQueueFlushesCleanly() async {
        let queue = makeQueue()
        let sent = await queue.flush()
        XCTAssertEqual(sent, 0)
    }

    func testCharmsAreSentSoTheServerCanRaiseTheCeiling() {
        let queue = makeQueue()
        queue.enqueue(record: record(), charmIDs: ["rush_job", "gem_cradle"],
                      serverSlabID: "abc", localSeed: nil)
        XCTAssertEqual(
            queue.pending.first?.wireFormat["charms"],
            .strings(["rush_job", "gem_cradle"])
        )
    }
}

final class InstallIdentityTests: XCTestCase {

    func testTheInstallIDIsStableAndAUUID() {
        let first = InstallIdentity.current()
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(InstallIdentity.current(), first,
                       "a changing install id would reset the player's lifetime share")
    }
}

final class LedgerFormattingTests: XCTestCase {

    func testLargeFiguresAreAbbreviatedAndSmallOnesAreNot() {
        // "$2.40B still owed" lands; "$2,400,000,000" is a wall of digits.
        XCTAssertEqual(CrewLedgerView.money(2_400_000_000), "$2.40B")
        XCTAssertEqual(CrewLedgerView.money(1_000_000), "$1.00M")
        XCTAssertEqual(CrewLedgerView.money(250_000_000), "$250.0M")
        XCTAssertEqual(CrewLedgerView.money(45_000), "$45k")
        XCTAssertEqual(CrewLedgerView.money(90), "$90")
        XCTAssertEqual(CrewLedgerView.money(0), "$0")
    }

    func testUnlockIdentifiersAreDescribedInWords() {
        XCTAssertEqual(CrewLedgerView.describeUnlock("site:hell_creek"), "Hell Creek, Montana")
        XCTAssertEqual(CrewLedgerView.describeUnlock("tool:sieve"), "Sieve")
        XCTAssertEqual(CrewLedgerView.describeUnlock("charmpool:vault"), "Rare charms")
        XCTAssertEqual(CrewLedgerView.describeUnlock("mode:new_game_plus"), "New game plus")
        // An identifier a future server knows about and this build does not must still read
        // as something rather than crashing or showing a raw key.
        XCTAssertEqual(CrewLedgerView.describeUnlock("widget:future_thing"), "Future thing")
        XCTAssertEqual(CrewLedgerView.describeUnlock("malformed"), "malformed")
    }
}

@MainActor
final class CrewLedgerStoreTests: XCTestCase {

    private func makeStore() -> CrewLedgerStore {
        let defaults = UserDefaults(suiteName: "bonedust.ledger.\(UUID().uuidString)")!
        let client = LedgerClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            installID: UUID().uuidString,
            attestation: LedgerAttestation(defaults: defaults)
        )
        return CrewLedgerStore(
            client: client,
            queue: PaymentQueue(
                client: client,
                storeURL: URL.temporaryDirectory.appending(path: "q-\(UUID().uuidString).json")
            ),
            defaults: defaults
        )
    }

    func testAnUnreachableLedgerLeavesTheGamePlayable() async {
        let store = makeStore()
        await store.refresh()
        XCTAssertFalse(store.isReachable)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.remaining, 0)
        XCTAssertFalse(store.hasEverLoaded)
        // The important part: nothing threw, and nothing is gated on it.
        XCTAssertFalse(store.hasUnlockedSite("hell_creek"))
    }

    func testIssuingASlabOfflineReturnsNil() async {
        let store = makeStore()
        let issued = await store.issueSlab(site: "charmouth")
        XCTAssertNil(issued)
    }

    func testUnlocksAreCachedAcrossLaunches() {
        // §6: milestone unlocks are cached once reached, so going offline cannot take
        // Hell Creek away again.
        let defaults = UserDefaults(suiteName: "bonedust.ledger.\(UUID().uuidString)")!
        defaults.set(["site:hell_creek"], forKey: "ledger.unlocks")
        let client = LedgerClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            installID: UUID().uuidString,
            attestation: LedgerAttestation(defaults: defaults)
        )
        let store = CrewLedgerStore(
            client: client,
            queue: PaymentQueue(
                client: client,
                storeURL: URL.temporaryDirectory.appending(path: "q-\(UUID().uuidString).json")
            ),
            defaults: defaults
        )
        XCTAssertTrue(store.hasUnlockedSite("hell_creek"))
    }

    func testRecordingASlabQueuesItEvenWithNoNetwork() {
        let store = makeStore()
        store.record(
            SlabRecord(
                day: 1, seed: 7, siteID: "charmouth", fossilID: "ammonite",
                payout: PayoutBreakdown(
                    baseValue: 90, exposure: 1, intact: 1, fossil: 90, gems: 0,
                    bonuses: 0, multiplier: 1, rushApplied: false, total: 90
                ),
                durationMillis: 40_000, bagged: true, wholeGems: 0, daylightLeft: 5,
                identified: true
            ),
            charmIDs: [], serverSlabID: nil, localSeed: 7
        )
        XCTAssertEqual(store.queue.pending.count, 1)
        XCTAssertEqual(store.queue.pendingTotal, 90)
    }
}
