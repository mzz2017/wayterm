#if os(iOS)
import CoreGraphics
import Foundation

struct TerminalSurfaceDisplaySizeState {
    private var lastPixelSize: CGSize = .zero
    private var lastContentScale: CGFloat = 0

    mutating func reset() {
        lastPixelSize = .zero
        lastContentScale = 0
    }

    mutating func resizeIfNeeded(pointSize: CGSize, scale: CGFloat) -> CGSize? {
        guard let pixelSize = Self.pixelSize(for: pointSize, scale: scale) else { return nil }
        guard pixelSize != lastPixelSize || scale != lastContentScale else { return nil }
        record(pixelSize: pixelSize, scale: scale)
        return pixelSize
    }

    mutating func forceResize(pointSize: CGSize, scale: CGFloat) -> CGSize? {
        guard let pixelSize = Self.pixelSize(for: pointSize, scale: scale) else { return nil }
        record(pixelSize: pixelSize, scale: scale)
        return pixelSize
    }

    private mutating func record(pixelSize: CGSize, scale: CGFloat) {
        lastPixelSize = pixelSize
        lastContentScale = scale
    }

    private static func pixelSize(for pointSize: CGSize, scale: CGFloat) -> CGSize? {
        guard pointSize.width > 0 && pointSize.height > 0 else { return nil }
        let pixelWidth = floor(pointSize.width * scale)
        let pixelHeight = floor(pointSize.height * scale)
        guard pixelWidth > 0 && pixelHeight > 0 else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
}

@MainActor
final class TerminalIOSSurfaceDisplayRuntime {
    private var sizeState = TerminalSurfaceDisplaySizeState()

    func resetSizeTracking() {
        sizeState.reset()
    }

    func resizeIfNeeded(surface: ghostty_surface_t, pointSize: CGSize, scale: CGFloat) -> Bool {
        guard let pixelSize = sizeState.resizeIfNeeded(pointSize: pointSize, scale: scale) else { return false }
        applySize(pixelSize, scale: scale, to: surface)
        return true
    }

    func forceResize(surface: ghostty_surface_t, pointSize: CGSize, scale: CGFloat) -> Bool {
        guard let pixelSize = sizeState.forceResize(pointSize: pointSize, scale: scale) else { return false }
        applySize(pixelSize, scale: scale, to: surface)
        return true
    }

    func setOcclusion(_ isVisible: Bool, surface: ghostty_surface_t) {
        ghostty_surface_set_occlusion(surface, isVisible)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e, surface: ghostty_surface_t) {
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    func redraw(surface: ghostty_surface_t) {
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
    }

    func writeOutput(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_write_output(surface, ptr, UInt(buffer.count))
        }
    }

    func externalExited(_ exitCode: UInt32, surface: ghostty_surface_t) {
        ghostty_surface_external_exited(surface, exitCode)
    }

    private func applySize(_ pixelSize: CGSize, scale: CGFloat, to surface: ghostty_surface_t) {
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(pixelSize.width), UInt32(pixelSize.height))
    }
}
#endif
