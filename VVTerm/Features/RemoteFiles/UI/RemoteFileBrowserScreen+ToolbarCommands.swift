import Foundation

extension RemoteFileBrowserScreen {
    func handlePendingToolbarCommand() {
        guard let command = browser.pendingToolbarCommand,
              command.serverId == server.id,
              command.tabId == fileTab.id else {
            return
        }

        switch command.action {
        case .upload(let destinationPath):
            beginUpload(to: destinationPath)
        case .createFolder(let destinationPath):
            beginCreateFolder(in: destinationPath)
        }

        browser.consumeToolbarCommand(command)
    }
}
