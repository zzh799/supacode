import ComposableArchitecture
import Foundation
import Sharing
import SupacodeSettingsShared

/// Root-path persistence for the local repository list. All other
/// sidebar slices (pin / collapse / repo order / worktree order /
/// focus / archive) moved to `@Shared(.sidebar)` + the
/// `SidebarPersistenceMigrator` — this client now only owns
/// `repositoryRoots`.
struct RepositoryPersistenceClient {
  var loadRoots: @Sendable () async -> [String]
  var saveRoots: @Sendable ([String]) async -> Void
  /// Remove the per-repository entries (`settingsFile.repositories`
  /// dict — scripts, run config, open action, _etc._) for repos that
  /// have been removed from Supacode so dead entries don't
  /// accumulate in `settings.json`. Pair with `saveRoots` at repo
  /// removal time; the two operate on different slices of the same
  /// settings file but share no enforced ordering.
  var pruneRepositoryConfigs: @Sendable ([String]) async -> Void
}

extension RepositoryPersistenceClient: DependencyKey {
  static let liveValue: RepositoryPersistenceClient = {
    RepositoryPersistenceClient(
      loadRoots: {
        @Shared(.repositoryRoots) var roots: [String]
        return roots
      },
      saveRoots: { roots in
        @Shared(.repositoryRoots) var sharedRoots: [String]
        $sharedRoots.withLock {
          // Normalize BEFORE the in-memory write: `withLock` mutates the
          // cached value in place and then persists it via the key's
          // `save` (which normalizes again, idempotently). If the value
          // written here stayed raw, any reader hitting the live cache
          // (rather than a fresh `load`) would see un-normalized,
          // duplicated roots until the reference was evicted - and tests
          // flip-flopped on whether the cache eviction happened between
          // save and load.
          $0 = RepositoryPathNormalizer.normalize(roots)
        }
      },
      pruneRepositoryConfigs: { repositoryIDs in
        guard !repositoryIDs.isEmpty else { return }
        let ids = Set(repositoryIDs.compactMap(RepositoryPathNormalizer.normalize))
        guard !ids.isEmpty else { return }
        @Shared(.settingsFile) var settingsFile: SettingsFile
        $settingsFile.withLock { settings in
          for id in ids {
            settings.repositories.removeValue(forKey: id)
          }
        }
      }
    )
  }()
  static let testValue = RepositoryPersistenceClient(
    loadRoots: { [] },
    saveRoots: { _ in },
    pruneRepositoryConfigs: { _ in }
  )
}

extension DependencyValues {
  var repositoryPersistence: RepositoryPersistenceClient {
    get { self[RepositoryPersistenceClient.self] }
    set { self[RepositoryPersistenceClient.self] = newValue }
  }
}
