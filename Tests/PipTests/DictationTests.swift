import XCTest
@testable import Pip

final class DictationTests: XCTestCase {
    func testSpeechGateRejectsTapAndSilenceBeforeInference() {
        XCTAssertFalse(DictationSpeechGate.hasSpeechCandidate(samples: Array(repeating: 1, count: 4_799)))
        XCTAssertFalse(DictationSpeechGate.hasSpeechCandidate(samples: Array(repeating: 0, count: 4_800)))
    }

    func testSpeechGateAcceptsARecordedVoiceLevel() {
        XCTAssertTrue(DictationSpeechGate.hasSpeechCandidate(samples: Array(repeating: 0.01, count: 4_800)))
    }
}
