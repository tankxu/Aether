# Aether

一个追求沉浸感的 iOS 浏览器：界面几乎不存在，内容铺满屏幕。

## 界面预览

以下为 iPhone 18 Pro 模拟器实拍。

| 首页 | 隐藏式快捷操作栏 | 网站收藏页 |
| --- | --- | --- |
| <img src="docs/screenshots/home.png" alt="Aether 星球首页与搜索入口" width="240"> | <img src="docs/screenshots/quick-actions.png" alt="网页上展开的液态玻璃快捷操作栏" width="240"> | <img src="docs/screenshots/favorites.png" alt="网站收藏页中的 Google、YouTube、Hacker News 和 Reddit" width="240"> |

首页提供实时星球背景和标准 / 无痕切换。快捷操作栏平时收起为屏幕边缘的细竖线，点击展开后可返回、刷新、回首页、新建或切换标签页；在首页向左翻页即可打开网站收藏。

**YouTube 全屏播放**：侧边播放控制与贴底进度条，画面上没有整块蒙版。

<img src="docs/screenshots/youtube-player.png" alt="Aether 播放 YouTube 视频：侧边控制与玻璃进度条" width="800">

**自动画中画设置**：在播放器的「⋯」菜单中切换，同时可设置常显进度条、旋转屏幕和播放速度。

<img src="docs/screenshots/pip-settings.png" alt="播放器菜单中的离开 App 时自动画中画选项" width="800">

此图展示画中画开关；本次模拟器环境未提供可用的 PiP 浮窗入口，未展示浮窗效果。实际可用性取决于设备与网站播放器。

**视频下载入口**：打开直链视频后，点击屏幕边缘的细竖线展开操作按钮，再在「⋯」菜单中选择「下载此文件」。

| 下载操作入口 | 视频下载完成 |
| --- | --- |
| <img src="docs/screenshots/download-entry.png" alt="视频文件的更多菜单中提供下载此文件操作" width="280"> | <img src="docs/screenshots/video-downloads.png" alt="视频下载列表与文件保存位置" width="280"> |

下载示例使用可直接访问的 MP4 文件，可在应用内预览、分享，或通过「文件」App 查看。此处演示的是直链视频下载。

视频画面来自 Blender Foundation 的 [Big Buck Bunny](https://peach.blender.org/)；[YouTube 播放示例](https://www.youtube.com/watch?v=aqz-KE-bpKQ)，[W3C 托管的下载示例](https://media.w3.org/2010/05/bunny/trailer.mp4)。视频及站点标识归各自权利人所有。

## 特性

- **单手操作友好**：常用操作集中在底部与屏幕侧边；边缘竖线可上下拖动、切换左右侧，视频播放控制列也可拖到另一侧，适应左右手握持。
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

[GNU AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.html)，全文见 [LICENSE](LICENSE)：

- 可以自由使用、修改、分发，包括商用
- 分发修改后的版本（包括以网络服务形式提供）时，必须以 AGPL-3.0 公开完整源码
- 必须保留原作者的版权和许可证声明

Copyright (C) 2026 Tank Xu
