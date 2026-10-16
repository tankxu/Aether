import Foundation

/// 排查真机问题用的简易日志：写到 Caches/aether-debug.log（不在“文件”App 里可见），
/// 用 devicectl 从设备上拉取。只保留最近的内容。
enum DebugLog {
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("aether-debug.log")
    private static let start = Date()

    static func log(_ message: String) {
        let line = String(format: "%.3f ", Date().timeIntervalSince(start)) + message + "\n"
        print("[Aether] " + message)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// 启动时截断过大的日志
    static func trim() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
