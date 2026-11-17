import Foundation
import Testing

/// Wait for the effect under test, with a deadline only to bound failures on CI.
@MainActor
func waitForTestCondition(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition(), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "Timed out waiting for the observed test condition")
}
