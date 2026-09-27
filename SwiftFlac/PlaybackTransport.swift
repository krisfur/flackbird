import AVFoundation

/// The transport boundary keeps queue and recovery rules independent of audio hardware.
@MainActor
protocol PlaybackTransport: AnyObject {
    var currentItem: AVPlayerItem? { get }
    var avPlayer: AVPlayer? { get }
    func currentTime() -> CMTime
    func replaceCurrentItem(with item: AVPlayerItem?)
    func play()
    func pause()
    func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
              completionHandler: @escaping @Sendable (Bool) -> Void)
}

extension AVPlayer: PlaybackTransport {
    var avPlayer: AVPlayer? {
        self
    }
}
