import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class SystemNotificationSettingsTests: XCTestCase {
    func testDeniedNotificationPathHasExplicitMacOSSettingsHandoff() {
        XCTAssertEqual(
            SystemNotificationSettingsModel.systemSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.notifications"
        )
    }

    func testOnlyGrantedAuthorizationStatesAreDeliverable() {
        XCTAssertTrue(SystemNotificationAuthorization.authorized.isDeliverable)
        XCTAssertTrue(SystemNotificationAuthorization.provisional.isDeliverable)
        XCTAssertTrue(SystemNotificationAuthorization.ephemeral.isDeliverable)
        XCTAssertFalse(SystemNotificationAuthorization.notDetermined.isDeliverable)
        XCTAssertFalse(SystemNotificationAuthorization.denied.isDeliverable)
        XCTAssertFalse(SystemNotificationAuthorization.unknown.isDeliverable)
    }

    func testRequestAuthorizationRechecksTheOSState() async {
        let center = RecordingNotificationCenter()
        let model = SystemNotificationSettingsModel(center: center)

        await model.refresh()
        XCTAssertEqual(model.authorization, .notDetermined)
        XCTAssertFalse(model.authorization.isDeliverable)

        await model.requestAuthorization()
        XCTAssertTrue(center.didRequestAuthorization)
        XCTAssertEqual(model.authorization, .authorized)
        XCTAssertTrue(model.authorization.isDeliverable)
    }
}

@MainActor
private final class RecordingNotificationCenter: SystemNotificationCenter {
    var authorizationValue: SystemNotificationAuthorization = .notDetermined
    private(set) var didRequestAuthorization = false

    func authorization() async -> SystemNotificationAuthorization {
        authorizationValue
    }

    func requestAuthorization() async -> Bool {
        didRequestAuthorization = true
        authorizationValue = .authorized
        return true
    }

    func post(title: String, body: String, identifier: String) async {}
}
