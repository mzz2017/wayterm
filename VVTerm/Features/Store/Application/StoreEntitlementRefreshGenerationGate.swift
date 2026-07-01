struct StoreEntitlementRefreshGenerationGate {
    struct Token: Equatable, Sendable {
        fileprivate let value: Int
    }

    private var generation = 0

    mutating func beginRefresh() -> Token {
        generation += 1
        return Token(value: generation)
    }

    func isCurrent(_ token: Token) -> Bool {
        token.value == generation
    }
}
