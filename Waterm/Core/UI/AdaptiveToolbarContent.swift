import SwiftUI

@ToolbarContentBuilder
func adaptiveFixedToolbarSpacer(
    placement: ToolbarItemPlacement = .automatic,
    fallbackWidth: CGFloat = 8
) -> some ToolbarContent {
    #if swift(>=6.1)
    if #available(iOS 26, macOS 26, *) {
        ToolbarSpacer(.fixed, placement: placement)
    } else {
        adaptiveToolbarSpacerFallback(placement: placement, width: fallbackWidth)
    }
    #else
    adaptiveToolbarSpacerFallback(placement: placement, width: fallbackWidth)
    #endif
}

@ToolbarContentBuilder
private func adaptiveToolbarSpacerFallback(
    placement: ToolbarItemPlacement,
    width: CGFloat
) -> some ToolbarContent {
    ToolbarItem(placement: placement) {
        Color.clear
            .frame(width: width, height: 1)
            .accessibilityHidden(true)
    }
}
