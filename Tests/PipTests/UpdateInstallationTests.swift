import XCTest
@testable import Pip

@MainActor final class UpdateInstallationTests: XCTestCase {
    func testBusyWorkDefersInstallationAndResumesExactlyOnceWhenIdle() {
        let gate = UpdateInstallationGate()
        var installed = 0
        XCTAssertTrue(gate.deferIfNeeded(isBusy: true) { installed += 1 })
        gate.resumeIfIdle(isBusy: true)
        XCTAssertEqual(installed, 0)
        gate.resumeIfIdle(isBusy: false)
        gate.resumeIfIdle(isBusy: false)
        XCTAssertEqual(installed, 1)
        XCTAssertFalse(gate.hasPendingInstallation)
    }

    func testIdleUpdateUsesSparklesNormalInstallationAndAbortDropsDeferredWork() {
        let gate = UpdateInstallationGate()
        var installed = false
        XCTAssertFalse(gate.deferIfNeeded(isBusy: false) { installed = true })
        XCTAssertFalse(installed)
        XCTAssertTrue(gate.deferIfNeeded(isBusy: true) { installed = true })
        gate.cancel()
        gate.resumeIfIdle(isBusy: false)
        XCTAssertFalse(installed)
    }
}
