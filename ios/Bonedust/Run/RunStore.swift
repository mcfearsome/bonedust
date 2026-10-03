import BonedustCore
import Foundation
import SwiftData

/// The single autosave slot (§5).
///
/// Run state, meta progress and the in-progress slab are stored as Codable blobs
/// rather than as SwiftData models with a property per field. That is deliberate:
/// they are already value types that round-trip through JSON, nothing ever queries
/// *inside* a saved run, and each carries its own `schema` int so a format change is
/// a version check instead of a SwiftData migration. Modelling `RunState` twice —
/// once as a struct for the simulation and once as a `@Model` for storage — would
/// double every future change for no gain.
@MainActor
final class RunStore {

    @Model
    final class SaveSlot {
        /// There is exactly one slot, per §5.
        @Attribute(.unique) var key: String
        var runPayload: Data?
        var slabPayload: Data?
        var metaPayload: Data?
        var updatedAt: Date

        init(key: String = SaveSlot.primaryKey) {
            self.key = key
            self.runPayload = nil
            self.slabPayload = nil
            self.metaPayload = nil
            self.updatedAt = Date()
        }

        static let primaryKey = "primary"
    }

    private let container: ModelContainer
    private let context: ModelContext
    /// True when the on-disk store could not be opened and we fell back to memory.
    let isEphemeral: Bool

    init(inMemory: Bool = false) {
        let schema = Schema([SaveSlot.self])
        func makeContainer(memoryOnly: Bool) throws -> ModelContainer {
            try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: memoryOnly)]
            )
        }
        if inMemory {
            // Force-try is acceptable for an in-memory store: it has no filesystem to
            // fail against, so a throw here would be a programming error.
            container = try! makeContainer(memoryOnly: true)
            isEphemeral = true
        } else if let disk = try? makeContainer(memoryOnly: false) {
            container = disk
            isEphemeral = false
        } else {
            // A corrupt or unopenable store must not brick the app. Losing a save is
            // bad; refusing to launch is worse.
            container = try! makeContainer(memoryOnly: true)
            isEphemeral = true
        }
        context = ModelContext(container)
    }

    // MARK: Slot

    private func slot() -> SaveSlot {
        let key = SaveSlot.primaryKey
        var descriptor = FetchDescriptor<SaveSlot>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { return existing }
        let fresh = SaveSlot()
        context.insert(fresh)
        return fresh
    }

    private func commit() {
        do {
            try context.save()
        } catch {
            // Nothing useful to do at the call site; the next save will try again.
            assertionFailure("save slot write failed: \(error)")
        }
    }

    // MARK: Meta

    func loadMeta() -> MetaProgress {
        guard let data = slot().metaPayload,
              let meta = try? JSONDecoder().decode(MetaProgress.self, from: data),
              meta.schema == MetaProgress.currentSchema
        else { return MetaProgress() }
        return meta
    }

    func save(meta: MetaProgress) {
        let target = slot()
        target.metaPayload = try? JSONEncoder().encode(meta)
        target.updatedAt = Date()
        commit()
    }

    // MARK: Run

    func loadRun() -> RunState? {
        guard let data = slot().runPayload,
              let run = try? JSONDecoder().decode(RunState.self, from: data),
              run.schema == RunState.currentSchema,
              !run.isOver
        else { return nil }
        return run
    }

    func save(run: RunState?) {
        let target = slot()
        target.runPayload = run.flatMap { try? JSONEncoder().encode($0) }
        if run == nil { target.slabPayload = nil }
        target.updatedAt = Date()
        commit()
    }

    // MARK: In-progress slab

    func loadSlab() -> SlabSnapshot? {
        guard let data = slot().slabPayload,
              let snapshot = try? JSONDecoder().decode(SlabSnapshot.self, from: data),
              snapshot.schema == SlabSnapshot.currentSchema
        else { return nil }
        return snapshot
    }

    func save(slab: SlabSnapshot?) {
        let target = slot()
        target.slabPayload = slab.flatMap { try? JSONEncoder().encode($0) }
        target.updatedAt = Date()
        commit()
    }

    func clearEverything() {
        let target = slot()
        target.runPayload = nil
        target.slabPayload = nil
        target.updatedAt = Date()
        commit()
    }
}
