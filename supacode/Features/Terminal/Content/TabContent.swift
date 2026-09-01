import AppKit

/// A tab's live content: stable identity, a renderer once the session has
/// started, and enough recorded state to snapshot across hibernation.
@MainActor
protocol TabContent: AnyObject, Sendable {
  nonisolated var id: ContentID { get }
  nonisolated var kind: ContentKind { get }
  /// The hosted view; nil until the session starts and while hibernated.
  nonisolated var renderer: NSView? { get }
  /// Whether closing now would interrupt real work (a terminal's foreground
  /// process); drives the busy-gated close confirmation.
  nonisolated var isBusy: Bool { get }
  /// Whether the renderer can be torn down with the session surviving (a
  /// terminal whose process lives in zmx).
  nonisolated var isHibernatable: Bool { get }
  /// Spawns the session eagerly at an explicit geometry; a second call while
  /// the renderer is alive is a no-op.
  nonisolated func startSession(at geometry: ContentGeometry)
  /// Tears down the renderer while the underlying session lives on, recording
  /// whatever the content needs to restore.
  nonisolated func hibernate()
  /// Releases the renderer and its live resources immediately on discard, so
  /// teardown runs at a deterministic point instead of a later dealloc.
  nonisolated func tearDown()
  /// Live, observable chrome for the tab strip; nil renders a bare tab.
  nonisolated var chrome: (any TabChrome)? { get }
  /// Live, observable toolbar docked at the top of the content region; nil
  /// docks nothing.
  var toolbar: (any TabContentToolbar)? { get }
  /// The current persistable state, including restoration data.
  nonisolated func snapshot() -> ContentSnapshot
}

extension TabContent {
  // Most content is never busy; terminals override with their process state.
  nonisolated var isBusy: Bool { false }
  // Hibernation is opt-in: only content whose session outlives the renderer
  // may claim it.
  nonisolated var isHibernatable: Bool { false }
  // Renderless content has nothing to release.
  nonisolated func tearDown() {}
  // Chrome is opt-in per content kind.
  nonisolated var chrome: (any TabChrome)? { nil }
  // A docked toolbar is opt-in per content kind.
  var toolbar: (any TabContentToolbar)? { nil }
}

/// Where in the layout a content is being created; a runtime hint for the
/// factory (terminals map it to Ghostty's surface context), never persisted.
nonisolated enum ContentOrigin: Equatable, Sendable {
  /// The first content of an empty layout.
  case first
  /// A tab added to an existing pane.
  case tab
  /// The initial tab of a freshly split pane.
  case split
  /// Content rebuilt from persisted state after a relaunch.
  case restored
}

/// Everything the factory needs to build one tab's content, kind and all.
nonisolated struct ContentRequest: Equatable, Sendable {
  var worktreeID: Worktree.ID
  var tabID: TabID
  var contentID: ContentID
  var content: ContentState
  var origin: ContentOrigin
  /// Source content whose live session seeds inheritable config (cwd, font).
  var inheritedFrom: ContentID?

  init(
    worktreeID: Worktree.ID,
    tabID: TabID,
    contentID: ContentID,
    content: ContentState,
    origin: ContentOrigin,
    inheritedFrom: ContentID? = nil
  ) {
    self.worktreeID = worktreeID
    self.tabID = tabID
    self.contentID = contentID
    self.content = content
    self.origin = origin
    self.inheritedFrom = inheritedFrom
  }
}

/// Renderless content that never starts a session; the fallback when a
/// factory cannot build the real thing, for any content kind.
@MainActor
final class InertTabContent: TabContent {
  let id: ContentID
  private let state: ContentState

  init(id: ContentID, state: ContentState) {
    self.id = id
    self.state = state
  }

  nonisolated var kind: ContentKind { state.kind }

  nonisolated var renderer: NSView? { nil }

  nonisolated func startSession(at geometry: ContentGeometry) {}

  nonisolated func hibernate() {}

  nonisolated func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: state)
  }
}

/// Terminal content backed by a Ghostty surface. The process itself lives in
/// zmx, so hibernation only drops the renderer, never the session.
@MainActor
final class TerminalContent: TabContent, @unchecked Sendable {
  let id: ContentID
  let kind: ContentKind = .terminal
  /// Instance-owned so badges, progress, and locks survive hibernation.
  let terminalChrome = TerminalTabChrome()
  /// Instance-owned so the docked find bar tracks this content's surface.
  private let searchToolbar: TerminalSearchToolbar

  nonisolated var chrome: (any TabChrome)? { MainActor.assumeIsolated { terminalChrome } }
  var toolbar: (any TabContentToolbar)? { searchToolbar }

  /// Which spawn a `makeSurface` call is; one-shot inheritance (source cwd,
  /// font, split context) applies to the first only, never a re-wake.
  nonisolated enum SpawnPhase: Equatable, Sendable {
    case first
    case rewake
  }

  /// A constructed surface plus whether its process lives in zmx, which is
  /// what makes renderer teardown recoverable.
  nonisolated struct SpawnedSurface {
    let view: GhosttySurfaceView
    let usesZmx: Bool
  }

  // Surface construction needs heavy config owned elsewhere, so it is
  // injected; it receives the current recorded state so a wake replans from
  // the hibernation-recorded grid and cwd, not the creation-time seed.
  private let makeSurface: (ContentGeometry, TerminalContentState, SpawnPhase) -> SpawnedSurface
  // Latest recorded terminal state, so hibernated snapshots stay truthful.
  private var state: TerminalContentState
  private var surfaceView: GhosttySurfaceView?
  private var usesZmx = false
  private var hasSpawned = false

  init(
    id: ContentID,
    makeSurface: @escaping (ContentGeometry, TerminalContentState, SpawnPhase) -> SpawnedSurface,
    initialState: TerminalContentState
  ) {
    self.id = id
    self.makeSurface = makeSurface
    self.state = initialState
    self.searchToolbar = TerminalSearchToolbar(contentID: id)
  }

  nonisolated var renderer: NSView? { MainActor.assumeIsolated { surfaceView } }

  // Hibernated terminals have no live surface, so nothing is interruptible.
  // A locked tab (completed blocking script) parks its runner alive, so
  // Ghostty keeps reporting confirm-quit for work nothing can lose; the lock
  // is the gate, NOT Ghostty's read-only bit, which a user can toggle on a
  // genuinely busy terminal.
  nonisolated var isBusy: Bool {
    MainActor.assumeIsolated {
      guard let surfaceView, !terminalChrome.isReadOnly else { return false }
      return surfaceView.needsCloseConfirmation
    }
  }

  // Only a zmx-backed live surface can drop its renderer and reattach.
  nonisolated var isHibernatable: Bool { MainActor.assumeIsolated { surfaceView != nil && usesZmx } }

  nonisolated func startSession(at geometry: ContentGeometry) {
    MainActor.assumeIsolated {
      guard surfaceView == nil else { return }
      let spawned = makeSurface(geometry, state, hasSpawned ? .rewake : .first)
      surfaceView = spawned.view
      searchToolbar.surfaceView = spawned.view
      usesZmx = spawned.usesZmx
      hasSpawned = true
    }
  }

  nonisolated func hibernate() {
    MainActor.assumeIsolated {
      guard let surfaceView else { return }
      state = recordedState(from: surfaceView)
      surfaceView.closeSurface()
      self.surfaceView = nil
      searchToolbar.surfaceView = nil
    }
  }

  // Free the Ghostty surface at event time: deferring to the view's dealloc
  // would run it mid-render when SwiftUI drops the last reference.
  nonisolated func tearDown() {
    MainActor.assumeIsolated {
      surfaceView?.closeSurface()
      surfaceView = nil
      searchToolbar.surfaceView = nil
    }
  }

  nonisolated func snapshot() -> ContentSnapshot {
    MainActor.assumeIsolated {
      guard let surfaceView else {
        return ContentSnapshot(id: id, state: .terminal(state))
      }
      return ContentSnapshot(id: id, state: .terminal(recordedState(from: surfaceView)))
    }
  }

  // Live values when the surface can report them, else the last recorded ones.
  private func recordedState(from surfaceView: GhosttySurfaceView) -> TerminalContentState {
    TerminalContentState(
      workingDirectory: surfaceView.bridge.state.pwd ?? state.workingDirectory,
      agents: state.agents,
      frozenGrid: surfaceView.captureFrozenGrid() ?? state.frozenGrid,
      launch: state.launch
    )
  }
}
