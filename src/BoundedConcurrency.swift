enum BoundedConcurrency {
    static func mapSuccessful<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        let results: [Output?] = try await self.map(inputs, limit: limit) { input in
            do {
                return try await operation(input)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }
        return results.compactMap { $0 }
    }

    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard !inputs.isEmpty else {
            return []
        }

        let limit = max(1, limit)

        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var iterator = inputs.enumerated().makeIterator()
            var results: [(Int, Output)] = []

            for _ in 0..<min(limit, inputs.count) {
                guard let (index, input) = iterator.next() else {
                    break
                }
                group.addTask {
                    (index, try await operation(input))
                }
            }

            while let result = try await group.next() {
                results.append(result)

                if let (index, input) = iterator.next() {
                    group.addTask {
                        (index, try await operation(input))
                    }
                }
            }

            return results
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }
}
