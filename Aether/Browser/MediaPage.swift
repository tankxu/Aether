import Foundation

/// 直接打开视频 / 音频文件时，用 Aether 自己的页面代替 WebKit 的媒体文档：
/// - 视频：媒体文档里的 <video> 被系统样式钉成居中小块，Aether 播放器铺不满；普通页面里的 <video> 才能正常接管。
///   不带系统控件，退出 Aether 播放器就离开这一页
/// - 音频：媒体文档只有一条系统控制条，做一张好看的播放卡片
/// 页面以文件地址为 baseURL 加载，同源、带 Cookie，地址栏显示的也还是文件地址。
enum MediaPage {
    enum Kind: String { case video, audio }

    static func kind(forMIME mime: String?) -> Kind? {
        guard let mime = mime?.lowercased() else { return nil }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        return nil
    }

    static func html(for url: URL, kind: Kind) -> String {
        let src = escape(url.absoluteString)
        let name = escape(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        let host = escape(url.host() ?? "")
        switch kind {
        case .video:
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <meta name="aether-media" content="video"><title>\(name)</title>
            <style>html,body{margin:0;height:100%;background:#000}video{display:block;width:100%;height:100%;object-fit:contain;background:#000}</style>
            </head><body><video src="\(src)" playsinline webkit-playsinline preload="auto"></video></body></html>
            """
        case .audio:
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <meta name="aether-media" content="audio"><meta name="theme-color" content="#0b0b14"><title>\(name)</title>
            <style>
            html,body{margin:0;height:100%}
            body{display:flex;align-items:center;justify-content:center;font:-apple-system-body;color:#fff;
              background:radial-gradient(120% 80% at 50% 0%,#2a2350 0%,#0b0b14 60%) fixed;-webkit-font-smoothing:antialiased}
            .card{width:min(86vw,380px);padding:32px 24px 26px;border-radius:32px;box-sizing:border-box;text-align:center;
              background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.14);
              -webkit-backdrop-filter:blur(30px) saturate(1.6);backdrop-filter:blur(30px) saturate(1.6);
              box-shadow:0 30px 80px rgba(0,0,0,.45)}
            .art{width:132px;height:132px;margin:0 auto 22px;border-radius:30px;display:grid;place-items:center;
              background:linear-gradient(145deg,#6d5dfc,#2a1f6b 70%);box-shadow:0 18px 40px rgba(80,60,220,.45),inset 0 1px 0 rgba(255,255,255,.25)}
            .art svg{width:58px;height:58px;fill:#fff;opacity:.92}
            .art.playing{animation:pulse 2.4s ease-in-out infinite}
            @keyframes pulse{50%{transform:scale(1.04);box-shadow:0 22px 56px rgba(110,90,255,.6),inset 0 1px 0 rgba(255,255,255,.25)}}
            h1{font:600 19px/1.3 -apple-system;margin:0 0 6px;word-break:break-word;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
            p{margin:0 0 24px;font-size:14px;color:rgba(255,255,255,.55)}
            audio{width:100%;color-scheme:dark}
            </style></head><body>
            <div class="card">
              <div class="art" id="art"><svg viewBox="0 0 24 24"><path d="M9 3v10.55A4 4 0 1 0 11 17V7h6V3H9z"/></svg></div>
              <h1>\(name)</h1><p>\(host)</p>
              <audio id="a" src="\(src)" controls preload="metadata"></audio>
            </div>
            <script>
            const a=document.getElementById('a'),art=document.getElementById('art');
            for(const t of ['play','playing'])a.addEventListener(t,()=>art.classList.add('playing'));
            for(const t of ['pause','ended','emptied'])a.addEventListener(t,()=>art.classList.remove('playing'));
            </script></body></html>
            """
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
