import Foundation

struct MediaTrack: Equatable {
    let index: Int
    let label: String
    let isOn: Bool
}

/// aether-player.js 上报的视频状态
struct PlayerState: Equatable {
    var time: Double
    var duration: Double
    var isLive: Bool
    var seekableStart: Double
    var seekableEnd: Double
    var buffered: Double
    var paused: Bool
    var ended: Bool
    var rate: Double
    var videoWidth: Double
    var videoHeight: Double
    var textTracks: [MediaTrack]
    var audioTracks: [MediaTrack]

    init(_ body: [String: Any]) {
        func number(_ key: String) -> Double { (body[key] as? NSNumber)?.doubleValue ?? 0 }
        func flag(_ key: String) -> Bool { (body[key] as? NSNumber)?.boolValue ?? false }
        func tracks(_ key: String) -> [MediaTrack] {
            (body[key] as? [[String: Any]] ?? []).enumerated().map { n, t in
                let index = (t["i"] as? NSNumber)?.intValue ?? n
                let label = (t["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "轨道 \(n + 1)"
                return MediaTrack(index: index, label: label, isOn: (t["on"] as? NSNumber)?.boolValue ?? false)
            }
        }
        time = number("t")
        duration = number("d")
        isLive = flag("live")
        seekableStart = number("ss")
        seekableEnd = number("se")
        buffered = number("buf")
        paused = flag("paused")
        ended = flag("ended")
        rate = number("rate") > 0 ? number("rate") : 1
        videoWidth = number("w")
        videoHeight = number("h")
        textTracks = tracks("text")
        audioTracks = tracks("audio")
    }

    var isPlaying: Bool { !paused && !ended }

    /// 可拖动的时间范围；直播用 seekable 窗口
    var range: ClosedRange<Double>? {
        if duration > 0 { return 0...duration }
        if seekableEnd > seekableStart + 1 { return seekableStart...seekableEnd }
        return nil
    }
}

enum PlayerCommand {
    case toggle
    case seekBy(Double)
    case seekTo(Double, fast: Bool)
    case rate(Double)
    case text(Int)
    case audio(Int)
    case exit

    var payload: [String: Any] {
        switch self {
        case .toggle: ["op": "toggle"]
        case .seekBy(let delta): ["op": "seekBy", "v": delta]
        case .seekTo(let time, let fast): ["op": "seekTo", "v": time, "fast": fast]
        case .rate(let r): ["op": "rate", "v": r]
        case .text(let i): ["op": "text", "v": i]
        case .audio(let i): ["op": "audio", "v": i]
        case .exit: ["op": "exit"]
        }
    }
}

enum TimeFormat {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
