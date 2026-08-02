import ComposableArchitecture
import Sparkle
import SupacodeSettingsShared

struct UpdaterClient {
  var configure: @MainActor @Sendable (_ checks: Bool, _ downloads: Bool, _ checkInBackground: Bool) -> Void
  var setUpdateChannel: @MainActor @Sendable (UpdateChannel) -> Void
  var checkForUpdates: @MainActor @Sendable () -> Void
}

@MainActor
class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
  var updateChannel: UpdateChannel = .stable

  nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    MainActor.assumeIsolated {
      switch updateChannel {
      case .stable:
        []
      case .tip:
        ["tip"]
      }
    }
  }
}

extension UpdaterClient: DependencyKey {
  static let liveValue: UpdaterClient = {
    // Sparkle's types are @MainActor, and TCA evaluates `liveValue` lazily on
    // whichever thread first touches `@Dependency(\.updaterClient)` — usually a
    // background thread. Two constraints rule out the obvious approaches:
    //
    // 1. A bare `MainActor.assumeIsolated` off the main thread traps
    //    (EXC_BREAKPOINT).
    // 2. A synchronous `DispatchQueue.main.sync` hop here deadlocks startup:
    //    TCA holds its dependency-cache lock while evaluating `liveValue`, so
    //    if the main thread is concurrently resolving any other dependency
    //    (e.g. `zmxClient` in `WorktreeTerminalManager.reapOrphanSessions`) it
    //    waits on that same lock while we wait on the main thread.
    //
    // So `liveValue` returns a client whose `@MainActor` closures lazily build
    // the Sparkle objects on the main actor on first use: no blocking while
    // holding the cache lock, and no off-main construction of @MainActor types.
    UpdaterClient(
      configure: { checks, downloads, checkInBackground in
        let updater = UpdaterRuntime.shared.updater
        updater.automaticallyChecksForUpdates = checks
        updater.automaticallyDownloadsUpdates = downloads
        if checkInBackground, checks {
          updater.checkForUpdatesInBackground()
        }
      },
      setUpdateChannel: { channel in
        let runtime = UpdaterRuntime.shared
        runtime.delegate.updateChannel = channel
        let updater = runtime.updater
        updater.updateCheckInterval = channel == .tip ? 43200 : 259200
        if updater.automaticallyChecksForUpdates {
          updater.checkForUpdatesInBackground()
        }
      },
      checkForUpdates: {
        UpdaterRuntime.shared.updater.checkForUpdates()
      }
    )
  }()

  static let testValue = UpdaterClient(
    configure: { _, _, _ in },
    setUpdateChannel: { _ in },
    checkForUpdates: {}
  )
}

/// Lazily owns the `@MainActor` Sparkle objects. The box itself carries no
/// Sparkle state (so it can be created on any thread); the controller is built
/// on the main actor when the first client method runs. Kept alive for the
/// process lifetime by `shared`.
@MainActor
private final class UpdaterRuntime {
  static let shared = UpdaterRuntime()

  let delegate = SparkleUpdateDelegate()
  lazy var controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: delegate,
    userDriverDelegate: nil
  )
  var updater: SPUUpdater { controller.updater }

  private init() {}
}

extension DependencyValues {
  var updaterClient: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
