import AVFoundation
import Foundation

#if os(iOS)
@MainActor
struct LiveAudioCaptureSession: AudioCaptureSessionManaging {
    func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: [])
    }

    func deactivateAfterRecording() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
#endif
