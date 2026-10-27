import XCTest
@testable import NativeHarnessClient

final class HarnessCenterListingProjectionTests: XCTestCase {
    func testConnectionFiltersRequireEvidenceAndDoNotTreatUnknownAsSetupFailure() throws {
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .grokBuild))
        for state in [AccountAuthState.signedIn, .signedOut, .actionRequired, .unavailable, .unknown] {
            let snapshot = HarnessAccountSnapshot(
                id: descriptor.id.rawValue, harness: descriptor.id, providerID: nil,
                state: state, accountLabel: nil, detail: "", credentialOwner: descriptor.displayName,
                checkedAt: Date(), usage: [], canLogin: false, canLogout: false
            )
            XCTAssertEqual(HarnessCenterListingProjection.matches(descriptor, snapshot: snapshot, query: "", filter: .connected), state == .signedIn)
            XCTAssertEqual(HarnessCenterListingProjection.matches(descriptor, snapshot: snapshot, query: "", filter: .attention), [.signedOut, .actionRequired, .unavailable].contains(state))
        }
        XCTAssertFalse(HarnessCenterListingProjection.matches(descriptor, snapshot: nil, query: "", filter: .connected))
        XCTAssertFalse(HarnessCenterListingProjection.matches(descriptor, snapshot: nil, query: "", filter: .attention))
        XCTAssertTrue(HarnessCenterListingProjection.matches(descriptor, snapshot: nil, query: "", filter: .all))
    }

    func testSearchMatchesFullHarnessNameAndID() throws {
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .claudeCode))
        XCTAssertTrue(HarnessCenterListingProjection.matches(descriptor, snapshot: nil, query: "  CLAUDE code\n", filter: .all))
        XCTAssertTrue(HarnessCenterListingProjection.matches(descriptor, snapshot: nil, query: "claude-code", filter: .all))
        XCTAssertFalse(HarnessCenterListingProjection.matches(descriptor, snapshot: nil, query: "codex", filter: .all))
    }

    func testManagementFixtureCoversEveryHarnessAndEveryConnectionState() {
        let snapshots = VisualFixtureScenario.harnessCenterSnapshots
        XCTAssertEqual(Set(snapshots.map(\.harness)), Set(HarnessCatalog.builtIns.map(\.id)))
        XCTAssertEqual(Set(snapshots.map(\.state)), Set([.signedIn, .signedOut, .actionRequired, .unavailable, .unknown]))
        XCTAssertEqual(VisualFixtureScenario.accountSnapshots.count, 3)
    }
}
