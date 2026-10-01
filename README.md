# Aether

一个追求沉浸感的 iOS 浏览器：界面几乎不存在，内容铺满屏幕。

## 特性

- **沉浸浏览**：没有常驻工具栏，只在屏幕边缘留一根细竖线，点一下才展开 Safari 风格的液态玻璃工具栏；状态栏底色和 iOS 26 Safari 一样，采样页面顶部的实际颜色。
- **不挡画面的视频播放器**：网页视频全屏时不进系统播放器，而是在页面内铺满，由原生层画控件。
  - 贴近底边的细玻璃进度条，支持相对拖动（任意位置按下拖）和绝对定位（按住进度竖线或点击）
  - 快退 10 秒 / 播放暂停 / 快进 10 秒竖排在屏幕一侧，可以拖到另一侧，没有任何蒙版
  - 保留网页的字幕轨道、音轨，支持倍速、自动横屏
  - 支持跨域 iframe 里的播放器、MSE / HLS 视频
- **广告过滤**：
  - 订阅 EasyList、AdGuard 中文、uBlock filters 等规则，在本机转换成 WebKit 内容拦截规则（约 7.5 万条）
  - 网页内脚本引擎执行 uBO scriptlet 和过程式选择器（`:has-text`、`:upward` 等）
  - 手动屏蔽页面元素、按网站停用过滤
- **无痕模式**、**历史记录**（带网站图标）、**按网站禁止跳转 App**、**地区与语言**（让 Google、YouTube 等按指定地区显示）
- **首页**：Metal 实时渲染的星球、行星环和弯曲的时空网格

## 构建

需要 Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)，没有任何第三方依赖。

```bash
xcodegen generate
open Aether.xcodeproj
```

真机签名：新建 `Config/Local.xcconfig`（已在 .gitignore 里），写上自己的团队：

```
DEVELOPMENT_TEAM = XXXXXXXXXX
```

## 说明

- 广告规则列表在运行时从各自官方地址下载，版权归原作者所有，仓库里只有一份自己写的少量内置规则（`Aether/AdBlock/aether-builtin.txt`）。
- 拦截通用链接（禁止跳转 App）用的是 WebKit 未公开的导航策略取值，自用没问题，上架 App Store 前需要评估。

## 许可证

[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/deed.zh-hans)（署名-非商业性使用-相同方式共享），全文见 [LICENSE](LICENSE)：

- 可以自由使用、修改、分发，但需署名
- **不得用于商业目的**
- 修改后再发布，必须沿用同一许可证
