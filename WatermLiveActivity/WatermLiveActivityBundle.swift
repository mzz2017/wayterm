#if os(iOS)
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
@main
struct WatermLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        WatermLiveActivityWidget()
    }
}
#endif
