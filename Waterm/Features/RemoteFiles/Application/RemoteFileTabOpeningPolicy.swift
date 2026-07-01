import Foundation

struct RemoteFileTabOpeningPlan: Equatable {
    let sourceTab: RemoteFileTab?
    let seedPath: String?
}

enum RemoteFileTabOpeningPolicy {
    static func newTabPlan(
        selectedFileTab: RemoteFileTab?,
        selectedFileTabLastVisitedPath: String?,
        fallbackWorkingDirectory: String?
    ) -> RemoteFileTabOpeningPlan {
        RemoteFileTabOpeningPlan(
            sourceTab: selectedFileTab,
            seedPath: selectedFileTabLastVisitedPath ?? fallbackWorkingDirectory
        )
    }
}
