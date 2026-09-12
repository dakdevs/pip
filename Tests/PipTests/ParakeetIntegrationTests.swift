import Foundation
import XCTest
import FluidAudio

/// This test is intentionally opt-in: it downloads a public audio fixture and
/// the Parakeet v3 model only when `PIP_TEST_PARAKEET=1` is set. It does not
/// open a microphone input or trigger a macOS microphone permission prompt.
final class ParakeetIntegrationTests: XCTestCase {
    func testParakeetV3TranscribesPublicFixture() async throws {
        guard ProcessInfo.processInfo.environment["PIP_TEST_PARAKEET"] == "1" else {
            throw XCTSkip("Set PIP_TEST_PARAKEET=1 to download and run the Parakeet integration test.")
        }

        let fixture = try await downloadFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let recognizer = AsrManager(config: .default, models: models)
        var state = TdtDecoderState.make(decoderLayers: await recognizer.decoderLayerCount)
        let result = try await recognizer.transcribe(fixture, decoderState: &state)
        let transcript = result.text.lowercased()

        XCTAssertFalse(transcript.isEmpty, "Parakeet returned an empty transcript.")
        XCTAssertTrue(transcript.contains("help them out"), "Unexpected transcript: \(result.text)")
    }

    private func downloadFixture() async throws -> URL {
        let source = URL(string: "https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.7/Tests/FluidAudioTests/ASR/Parakeet/SlidingWindow/Fixtures/01-validation-request-21.4s.wav")!
        let (data, response) = try await URLSession.shared.data(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "PipParakeetIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not download the public FluidAudio fixture."])
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("pip-parakeet-\(UUID().uuidString).wav")
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
