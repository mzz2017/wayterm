import Foundation

extension KeychainManager: ServerCredentialWritingLibrary {}

extension ServerCredentialPersistence {
    static let shared = ServerCredentialPersistence(library: KeychainManager.shared)
}
