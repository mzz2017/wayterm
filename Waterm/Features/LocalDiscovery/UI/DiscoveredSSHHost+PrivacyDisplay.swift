extension DiscoveredSSHHost {
    var displayEndpoint: String {
        "\(host):\(port)"
    }

    func visibleDisplayName(privacyModeEnabled _: Bool) -> String {
        return displayName
    }

    func visibleEndpoint(privacyModeEnabled _: Bool) -> String {
        displayEndpoint
    }
}
