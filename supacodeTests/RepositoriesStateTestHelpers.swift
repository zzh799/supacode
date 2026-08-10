import ComposableArchitecture
import Foundation

@testable import supacode

extension RepositoriesFeature.State {
  /// Seed an active removal batch for tests that drop straight
  /// into `.deleteSidebarItemConfirmed` / `.deleteScriptCompleted`
  /// without going through the confirm handler that normally
  /// mints the id and records dispositions. Callers pass the
  /// disposition each pending repo was confirmed with so the
  /// per-repo record stays coherent. Returns the batch id so
  /// tests can assert its lifecycle.
  ///
  /// Lives in the test target (not the main module) so production
  /// code can't accidentally seed the removal state machine
  /// externally — the `.requestDeleteSidebarItems` →
  /// `.confirmDeleteSidebarItems` flow owns that setup — and a
  /// misuse from production code would silently corrupt the batch
  /// aggregator.
  @discardableResult
  mutating func seedRemovalBatch(
    pending: [Repository.ID: RepositoriesFeature.DeleteDisposition],
    id: RepositoriesFeature.BatchID = UUID()
  ) -> RepositoriesFeature.BatchID {
    for (repositoryID, disposition) in pending {
      removingRepositoryIDs[repositoryID] = RepositoriesFeature.RepositoryRemovalRecord(
        disposition: disposition, batchID: id
      )
    }
    activeRemovalBatches[id] = RepositoriesFeature.ActiveRemovalBatch(
      id: id, pending: Set(pending.keys)
    )
    return id
  }
}

extension TestStore where State == RepositoriesFeature.State, Action == RepositoriesFeature.Action {
  /// Alert-confirm arms defer their sidebar mutations until the confirmation
  /// sheet has finished closing (`RepositoriesFeature.sidebarAlertDismissalDeferral`),
  /// so the confirm action itself no longer seeds batches or flips rows.
  /// Tests that confirm an alert must inject a `TestClock` as
  /// `continuousClock` and drive it past the deferral with this helper before
  /// asserting on the deferred work.
  func advancePastAlertSheetClose(using clock: TestClock<Duration>) async {
    await clock.advance(by: RepositoriesFeature.sidebarAlertDismissalDeferral)
  }
}
