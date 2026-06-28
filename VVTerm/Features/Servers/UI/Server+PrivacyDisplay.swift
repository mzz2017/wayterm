extension Server {
    var displayAddressWithPort: String {
        "\(username)@\(host):\(port)"
    }

    func visibleHost(privacyModeEnabled: Bool) -> String {
        SensitiveContentMask.value(host, privacyModeEnabled: privacyModeEnabled)
    }

    func visibleAddress(privacyModeEnabled: Bool) -> String {
        privacyModeEnabled ? SensitiveContentMask.placeholder : displayAddressWithPort
    }
}
