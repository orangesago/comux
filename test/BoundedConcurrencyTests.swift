import XCTest
@testable import Comux

final class BoundedConcurrencyTests: XCTestCase {
    func testSuccessfulMapKeepsOtherWorkspaceReadsAfterUnauthorizedResponse() async throws {
        let results = try await BoundedConcurrency.mapSuccessful(
            Array(0..<6),
            limit: 2
        ) { workspace in
            if workspace == 0 || workspace == 3 {
                _ = try UsagePayloadParser.parse(
                    data: Data(#"{"error":{"code":"token_expired"}}"#.utf8),
                    response: HTTPURLResponse(
                        url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: nil
                    )
                )
            }
            try await Task.sleep(for: .milliseconds(6 - workspace))
            return workspace
        }

        XCTAssertEqual(results, [1, 2, 4, 5])
    }

    func testSuccessfulMapReturnsNoSnapshotsWhenAllWorkspaceReadsFail() async throws {
        let results: [Int] = try await BoundedConcurrency.mapSuccessful([0, 1], limit: 2) { _ in
            throw PulseError.invalidUsageResponse
        }

        XCTAssertTrue(results.isEmpty)
    }

    func testSuccessfulMapPropagatesCancellation() async {
        do {
            let _: [Int] = try await BoundedConcurrency.mapSuccessful([0], limit: 1) { _ in
                throw CancellationError()
            }
            XCTFail("Cancelled refresh should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLimitsConcurrencyAndPreservesInputOrder() async throws {
        let probe = ConcurrencyProbe()

        let results = try await BoundedConcurrency.map(
            Array(0..<6),
            limit: 2
        ) { value in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(10 * (6 - value)))
            await probe.leave()
            return value
        }

        let maximumActive = await probe.maximumActive
        XCTAssertEqual(maximumActive, 2)
        XCTAssertEqual(results, Array(0..<6))
    }

    func testTreatsNonpositiveLimitAsOne() async throws {
        let probe = ConcurrencyProbe()

        _ = try await BoundedConcurrency.map(Array(0..<3), limit: 0) { value in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(5))
            await probe.leave()
            return value
        }

        let maximumActive = await probe.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }
}

private actor ConcurrencyProbe {
    private var active = 0
    private(set) var maximumActive = 0

    func enter() {
        self.active += 1
        self.maximumActive = max(self.maximumActive, self.active)
    }

    func leave() {
        self.active -= 1
    }
}
