import AVFoundation
import Foundation

/// Zero-latency polyphonic UI sound engine backed by preloaded 44.1 kHz `.caf` tactile assets.
/// Maintains `0.0%` idle CPU and respects user sound toggle, volume, and rate limits.
@MainActor
public final class SoundEngine {
    public static let shared = SoundEngine()

    public enum Effect: String, CaseIterable, Sendable {
        case click = "click"
        case hoverTick = "hover_tick"
        case metricPop = "metric_pop"
        case morph3D = "morph_3d"
        case morph2D = "morph_2d"
        case liveChime = "live_chime"

        var minIntervalSeconds: CFAbsoluteTime {
            switch self {
            case .hoverTick: 0.042
            case .liveChime: 12.0
            case .click, .metricPop: 0.03
            case .morph3D, .morph2D: 0.12
            }
        }

        var voicePoolSize: Int {
            switch self {
            case .hoverTick: 4
            case .click, .metricPop: 2
            case .morph3D, .morph2D, .liveChime: 2
            }
        }
    }

    public var isEnabled: Bool = true
    public var volume: Float = 0.65

    private var pools: [Effect: [AVAudioPlayer]] = [:]
    private var nextVoiceIndex: [Effect: Int] = [:]
    private var lastPlayedAt: [Effect: CFAbsoluteTime] = [:]
    private let isTestHost: Bool

    private init() {
        self.isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    public func play(_ effect: Effect, force: Bool = false) {
        guard !isTestHost else { return }
        guard force || isEnabled else { return }
        let effectiveVolume = max(0, min(1, volume))
        guard effectiveVolume > 0.005 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if !force, let last = lastPlayedAt[effect], (now - last) < effect.minIntervalSeconds {
            return
        }
        lastPlayedAt[effect] = now

        let pool = poolFor(effect)
        guard !pool.isEmpty else { return }

        let idx = nextVoiceIndex[effect, default: 0] % pool.count
        nextVoiceIndex[effect] = idx + 1
        let player = pool[idx]
        player.volume = effectiveVolume
        if player.isPlaying {
            player.currentTime = 0
        }
        player.play()
    }

    private func poolFor(_ effect: Effect) -> [AVAudioPlayer] {
        if let existing = pools[effect] {
            return existing
        }
        // Check both flat Resources/ and Resources/Sounds/ subdirectory inside app bundle
        let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "caf", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: effect.rawValue, withExtension: "caf")
        guard let url else {
            pools[effect] = []
            return []
        }

        var players: [AVAudioPlayer] = []
        players.reserveCapacity(effect.voicePoolSize)
        for _ in 0..<effect.voicePoolSize {
            if let p = try? AVAudioPlayer(contentsOf: url) {
                p.prepareToPlay()
                players.append(p)
            }
        }
        pools[effect] = players
        return players
    }
}
