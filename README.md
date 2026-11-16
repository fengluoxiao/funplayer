；# funPlayer

一款专为 iOS 打造的 Jellyfin 媒体播放器，支持音乐、电影、电视剧的流畅播放与优雅体验。

---

## 功能特性

- **Jellyfin 连接**：支持添加多个 Jellyfin 服务器，自动认证并管理媒体库
- **多类型媒体支持**：音乐专辑、单曲、电影、电视剧（含季/集浏览）
- **精美播放器界面**：
  - 全屏播放器，支持动态取色（根据封面自动调整主题色）
  - 毛玻璃背景 + 高斯模糊封面效果
  - 迷你播放器常驻底部，支持播放/暂停、切歌
  - 封面缓存，切歌无闪烁
- **完整播放控制**：
  - 播放/暂停、上一首/下一首
  - 进度拖拽、快进快退
  - 随机播放、单曲/全部循环
  - 系统音量控制、AirPlay 投送
- **锁屏与控制中心**：支持系统级远程控制、Now Playing 信息展示
- **媒体库浏览**：按类型自动分类，支持最近播放、最近添加
- **本地化支持**：界面文本支持多语言（基于 String Catalog）

---

## 技术栈

- **SwiftUI** + **SwiftData**（数据持久化）
- **AVFoundation**（音频播放）
- **MediaPlayer**（锁屏控制、音量条）
- **Jellyfin API**（RESTful 通信，支持直链/转码/HLS）

---

## 项目结构

```
funPlayer/
├── funPlayerApp.swift          # 应用入口，SwiftData 容器配置
├── ContentView.swift           # 主界面（TabView + MiniPlayer）
├── Models/
│   ├── ServerConfig.swift      # 服务器配置模型（SwiftData）
│   └── JellyfinModels.swift    # Jellyfin API 数据模型
├── Services/
│   ├── JellyfinClient.swift    # Jellyfin 网络客户端
│   ├── PlayerManager.swift     # 音频播放管理（AVPlayer 封装）
│   └── AppState.swift          # 全局应用状态
├── Views/
│   ├── ServerSetupView.swift   # 添加服务器 + 库选择
│   ├── LibraryView.swift       # 媒体库浏览（专辑/季/集）
│   ├── FullScreenPlayer.swift  # 全屏播放器
│   ├── MiniPlayer.swift        # 底部迷你播放器
│   └── PlayerControls.swift    # 自定义滑条与控件
└── Assets.xcassets/            # 应用图标与颜色资源
```

---

## 使用说明

1. 首次打开应用，点击「Add Server」添加你的 Jellyfin 服务器地址、账号和密码
2. 连接成功后选择要浏览的媒体库（音乐/电影/电视剧）
3. 在「Home」标签查看最近播放和最近添加
4. 在「Library」标签浏览完整媒体库
5. 点击任意媒体项即可播放，底部会弹出迷你播放器
6. 点击迷你播放器进入全屏，享受沉浸式播放体验

---

## 系统要求

- iOS 17.0+
- Xcode 15.0+
- 需要 Jellyfin 服务器（10.8+ 推荐）

---

## 开源协议

---

## GitHub Actions 打包 IPA

工作流为 `.github/workflows/build-ipa.yml`，使用 GitHub 官方的 `xcode-27`
runner（macOS 27 / Xcode 27，当前为公开预览版）。
项目仍保持 iOS 26.4 的部署目标，构建 SDK 跟随 runner 中的 Xcode。

- 推送 iOS 源码、Xcode 工程或构建配置后自动打包，Pull Request 也会构建。
- 工作流合并到默认分支后，也可在 **Actions → Build iOS IPA → Run workflow** 手动触发。
- 构建成功后，在该次运行的 **Artifacts** 中下载 `funPlayer-unsigned-ipa`。
  解压下载的 ZIP，即可获得 `funPlayer-unsigned.ipa`。
- 产物为 **arm64 真机未签名 IPA**，无需配置 Apple 证书或 GitHub Secrets。
  安装前须使用自己的证书及描述文件签名；不能直接提交 TestFlight 或 App Store。
- IPA 保留 14 天；构建日志和 Xcode 结果包保留 7 天，供失败排查。

在安装 Xcode 27 的 Mac 上，也可以执行 `bash scripts/build-ipa.sh`，
产物位于 `build/funPlayer-unsigned.ipa`。重复构建前需移走或清理之前的
`build/Build.xcresult` 和归档、打包目录。
