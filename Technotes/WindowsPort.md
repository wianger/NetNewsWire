# NetNewsWire for Windows —— 技术路线调研与决策

调研日期：2026-11-25

## 1. 现状盘点（代码库）

| 层 | 规模（Swift 行数，含测试） | Windows 可移植性 |
|---|---|---|
| `Modules/`（Account、RSParser、RSWeb、ArticlesDatabase、SyncDatabase 等） | ~61K | **基本可移植**：主要依赖 Foundation |
| `Shared/`（渲染、智能订阅源、命令） | ~7.4K | 部分可移植（WebKit/AppKit/UIKit 需隔离） |
| `Mac/`（AppKit） | ~22.6K | 不可移植，需重写 UI |
| `iOS/`（UIKit） | ~17.7K | 不可移植 |

核心模块中阻碍 Windows 编译的具体问题：

1. **FMDB（Objective-C，约 3.4K 行）**：位于 `RSDatabaseObjC`。Windows 上的 Swift 没有 ObjC 运行时。26 个 Swift 文件调用它，使用的 API 很少（`executeQuery`、`executeUpdate`、`FMResultSet` 取列、若干 `rs_` 扩展）。
2. **`import os`（Logger）**：约 40 个文件。
3. **Security / Keychain**（`Secrets`）：需要对接 Windows Credential Manager。
4. **CloudKit / CloudKitSync**：Windows 上没有 iCloud，只能整体排除。
5. **SystemConfiguration、Network、ImageIO、UniformTypeIdentifiers、CoreGraphics**：用到的地方不多，可以按平台条件编译。
6. **`@objc` / `NSObject` / `#selector`**：约 129 处（不含 AppKit/UIKit 目录），需要逐个审查。
7. **`@MainActor`（360 处）+ `NotificationCenter`（106 处）**：在 Windows 上，主执行器（main executor）需要接入宿主 UI 线程（见 §3.3）。
8. 第三方依赖 **Tidemark** 是纯 Swift，没有平台 API 依赖，可移植。

## 2. 候选路线与调研结论

### A. 全 Swift：Swift 核心 + Swift 直接驱动 WinUI 3
- The Browser Company 的 `swift-winui`、`swift-windowsappsdk` **已于 2025-10 归档**，锁定在 Windows App SDK 1.7，且只支持 x64。微软对该版本的支持已于 2026-03-18 结束。
- 社区 fork `moreSwift/swift-winui` 只有一名维护者。`swift-winrt` 仍在维护。
- 大型模块会撞上 DLL 导出符号上限（65535）。这是 PE 格式的硬限制，有人在 Swift 6.1 上遇到过。
- `swift-cross-ui`（类 SwiftUI，有 WinUIBackend，v0.11）有一个 **Narrator 等 UI 自动化客户端会让应用崩溃**的未修复问题（#787，涉及 List、ScrollView、TextField）。对阅读器来说，无障碍是硬性要求。
- `windows-kit`（2026-07 发布的新 Win32 + WinRT 投影）和 COM 互操作 vision pitch 都还处于早期。
- **结论**：方向最前沿，但目前不适合生产。保留为远期选项：UI 层通过稳定的边界与核心解耦，以后可以换成 Swift。

### B. Swift 核心 DLL + C#/WinUI 3 原生 UI（**推荐**）
- Swift 6.3（2026-03）正式提供 `@c`（SE-0495），可以导出单一入口的 C ABI 函数和 C 兼容枚举，取代非正式的 `@_cdecl`。
- Swift 6.3 把 Swift Build 预览集成进 SwiftPM；**Swift 6.4（2026-09-15，当前为 6.4.3）起 Swift Build 成为 SwiftPM 默认构建系统**，Linux、macOS、Windows 构建行为一致；Subprocess 1.0。Swift 可通过 WinGet 或 Scoop 安装（Windows 上还需要 Visual Studio Build Tools 和 Windows SDK）。
- Windows App SDK **2.7.0**（2026-11-17）+ .NET 10：微软一方 UI 栈，无障碍、高 DPI、Fluent、Mica、通知、打包都是原生支持。
- 已有 2026 年的公开实践：ClaudeBar-Windows 把 Swift 6.3.3 DLL（`@c` 导出）接到 .NET 10 + WinAppSDK 2.5.1 的 WinUI 3 应用上并跑通。其 NativeAOT 产物约 119MB，其中 Swift 运行时约 57MB。
- 文章渲染可以沿用现有的 HTML 模板和主题（`Shared/Article Rendering`、`Themes/`），用 **WebView2** 承载，代替 WKWebView。
- 已知风险：Swift DLL 被 .NET 宿主加载时，`@MainActor` 任务可能不执行（Swift Forums #88469，Swift 6.3.2）。见 §3.3。

### C. 推倒重写（Rust + Tauri 2 / Slint，或 .NET 全栈，或 Flutter、KMP）
- 要重写约 61K 行已经验证过的同步与解析逻辑（Feedbin、Feedly、NewsBlur、Reader API、Miniflux 等），之后还得长期维护两套实现，行为会逐渐分叉。
- **结论**：成本最高、收益最低，否决。

## 3. 决策：路线 B

```
┌──────────────────────────── NetNewsWire.exe (.NET 10, WinUI 3, WinAppSDK 2.x) ───┐
│  Sidebar / Timeline / Detail (XAML)      Detail = WebView2 + 现有 HTML 模板/主题    │
│  ViewModels (CommunityToolkit.Mvvm)                                                │
│        │  P/Invoke（由 Swift 生成的 C 头文件经 ClangSharpPInvokeGenerator 生成）      │
└────────┼───────────────────────────────────────────────────────────────────────────┘
         ▼
┌──────────── NetNewsWireCore.dll (Swift 6.3, @c 导出的窄门面 API) ────────────────────┐
│  Account / RSParser / RSWeb / ArticlesDatabase / SyncDatabase / FeedFinder / Images │
│  RSDatabase（纯 Swift SQLite 封装，替换 FMDB）   Secrets（Credential Manager 后端）  │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 边界设计
- **一个请求入口，而不是几十个导出函数**（M2 定稿）：C ABI 只有 `nnw_core_start`（启动，并注册事件回调）、`nnw_request(method, paramsJSON, context, callback)`（异步请求，回调里给 `{"result": …}` 或 `{"error": {code, message}}`）和 `nnw_string_free`，另加 M0 的主队列桥接函数。功能全部是 `CoreService` 里 `noun.verb` 形式的方法，加功能不改 ABI，也不改 P/Invoke 声明，所以不再需要 ClangSharpPInvokeGenerator。这和 LSP、Tauri 的命令通道是同一种做法：类型安全放在两端（Swift `Codable`，C# 记录类型加 `System.Text.Json` 源生成，可裁剪，兼容 Native AOT），边界本身保持最小。JSON 的开销相对网络和 SQLite 可以忽略；时间线一次取上千条摘要也只是几百 KB。
- 跨边界只传值，不传 Swift 对象：C# 侧不用管 Swift 对象的生命周期。文件夹的 `folderID` 只在本次运行内有效，C# 侧每次从 `sidebar.get` 取。
- 事件（`sidebarChanged`、`unreadCountsChanged`、`statusesChanged`、`articlesChanged`、`refreshProgress`）在主队列的一轮里合并后再发，刷新时不会刷屏 UI 线程。
- 核心模块仍是各自的 DLL（Account.dll、RSCore.dll……），跟 `NetNewsWireCore.dll` 一起复制到应用目录；对外只有 `nnw_*` 这几个符号是入口，65535 导出符号上限不是问题。
- `CoreService` 是普通的 Swift 库，测试直接用方法名和 JSON 驱动它（`Windows/Core/Tests`），不经过 C ABI。

### 3.2 核心模块的移植
| 问题 | 方案 |
|---|---|
| FMDB（ObjC） | 用纯 Swift 重写所用的 FMDB 子集（`RSDatabase/Sources/RSDatabase/SwiftFMDB`），直接调用 SQLite3 C API；类名、签名、绑定规则和生成的 SQL 与 ObjC 版一致，26 个调用文件不用改。目前只在没有 ObjC 的平台上启用，macOS/iOS 仍用 ObjC FMDB，等 Mac 上验证过再考虑统一。SQLite 用内置的 3.54.1 amalgamation（`Sources/CSQLite`，开启 FTS3/4/5；工具链自带的 SQLite 没有 FTS，而搜索依赖 FTS4）。GRDB 7.10 起声称支持 Windows，但维护者明确表示**不保证** Windows 兼容，所以不选。 |
| `os.Logger` | `RSCore/Logger+NonApple.swift`：在没有 `os` 的平台上提供同名的 `Logger`/`OSLogMessage`/`OSLogPrivacy`，支持 `privacy:` 和 `format: .fixed(precision:)`，输出到 stderr 和 `OutputDebugStringW`，可替换 `Logger.sink`。调用点只需把 `import os` 改成条件导入。没用 swift-log：它的插值写法不同，所有调用点都得改。 |
| Keychain | `CredentialsManager` 的 Windows 实现（`Secrets/CredentialsManager+Windows.swift`）：通用凭据存入 Credential Manager（`CredWriteW`/`CredReadW`/`CredDeleteW`，DPAPI 按用户加密），目标名为 `NetNewsWire/<类型>/<服务器>/<用户名>`，公开 API 不变。 |
| HTTP（URLSession） | Windows 上换成 WinHTTP（`RSWeb/Windows/WinHTTPClient.swift`，C 头文件目标 `CWinHTTP`）。`DownloadSession`（订阅源刷新）、`Downloader`（图标、图片）和网络服务调用（`URLSession` 的 `send`/`webserviceData`）在 `#if os(Windows)` 下走它，Mac/iOS 路径不变；单元测试照旧走 `URLSession` + `TestingURLProtocol`。原因和测量见 §4.4。 |
| CloudKit | 用 `#if canImport(CloudKit)` 整体排除；Windows 上不提供 iCloud 账户。 |
| ImageIO / UTType / CGImage | 解码留在核心里，Windows 上由 WIC（Windows Imaging Component，Direct2D 和 WinUI `BitmapDecoder` 用的同一套编解码器）完成：`RSCore/Windows/WICImaging.swift` 通过 WinSDK 模块直接调 COM 接口，提供取最大帧、按 EXIF 方向解码、高质量缩放（`HighQualityCubic`）和 PNG/JPEG/TIFF 编码。Windows 版 `RSImage` 是解码好的预乘 BGRA 位图（`RSBitmap`），UI 层直接交给 `SoftwareBitmap`。亮度判断、灰度图、模板着色与 Apple 平台的算法相同，所以缩略图和图标的行为两边一致，也能用同一组测试。没有选“把解码交给 UI 层”：那样缓存缩放、缩略图裁剪和亮度判断都得用 C# 重写一遍。SVG 在 WIC 里没有解码器，和 iOS 一样不支持。`UTType` 只用于识别 SVG 图标，改为按 MIME 类型和扩展名判断。 |
| `Thread.isMainThread` | Swift Testing 的异步入口调用 `dispatch_main()` 后，主队列（即主执行器）由工作线程排空，这时 `@MainActor` 代码运行在 `isMainThread` 为 false 的线程上。`BatchUpdate` 甚至会在主队列上 `DispatchQueue.main.sync` 自己而死锁。新增 `Thread.isMainQueue`：Apple 平台上就是 `isMainThread`，行为不变；其他平台上用主队列的 `DispatchSpecificKey` 判断。核心里的检查都改用它。 |
| `@objc`、`NSObject` | 逐个审查，改成纯 Swift（闭包、协议、`Mutex`）。例：`CoalescingQueue` 新增闭包接口，selector 接口只在有 ObjC 的平台保留。 |
| `Network.framework` | `NetworkMonitor` 的 Windows 实现用 `NotifyNetworkConnectivityHintChange`（Windows 10 2004+）：连接级别对应 `isConnected`；按流量计费、漫游或接近/超出流量上限对应 `isConstrained`（相当于低数据模式）。 |
| CryptoKit | 非 Apple 平台用 swift-crypto（同一套 API）。 |
| `CFStringEncodings` | Windows 的 Foundation 不公开 CoreFoundation；RSParser 用 CF 编码常量的原始值（`0x8000_0000 \| kCFStringEncoding…`）构造 `String.Encoding`。 |
| 主 RunLoop 上的 `Timer` | Windows 上主线程由 WinUI 驱动，主 RunLoop 不运行，挂在上面的 `Timer` 永远不会触发。改用 `Task.sleep` 或 dispatch。 |

### 3.3 并发与主线程
- 核心里的 `@MainActor` 是给 UI 用的。在 Windows 上，核心改为由**自己拥有的一条 Swift 线程**承载主执行器（启动时在 DLL 内创建线程，并运行 `RunLoop`/dispatch main），C# 侧只通过回调接收结果。
- 跟进 Swift Evolution「Custom Main and Global Executors」（目前仍处于 pitch 3 阶段）。落地后改为基于 `DispatcherQueue` 的自定义主执行器。
- **已采用并验证（M0）的方案**：让 Swift 的 `@MainActor` 直接运行在 WinUI UI 线程上，语义与 macOS/iOS 一致。
  - 原理：Windows 上 Swift 的主执行器把任务投递到 libdispatch 主队列。主队列有一个 Win32 事件句柄，可通过 `_dispatch_get_main_queue_handle_4CF` 取得，`dispatch.dll` 导出了这个符号。
  - C# 侧开一条后台线程等待这个句柄；句柄被触发时，通过 `DispatcherQueue.TryEnqueue` 在 UI 线程上调用 `nnw_drain_main_queue`，后者先 `ResetEvent`，再调用 `_dispatch_main_queue_callback_4CF`。
  - 前提：核心 DLL 必须在 UI 线程上首次加载，主队列才会绑定到 UI 线程。`SwiftCore.Start` 会对此做断言。
  - 实现见 `Windows/Core/Sources/NetNewsWireCore/MainQueueBridge.swift`、`Windows/App/Core/SwiftCore.cs`。
- 跟进 Swift Evolution「Custom Main and Global Executors」（目前仍处于 pitch 3 阶段）。落地后改为正式的 `DispatcherQueue` 自定义主执行器，去掉对私有 `_4CF` 符号的依赖。

### 3.4 构建与 CI
- Swift 6.4.x（官方安装器，`winget install Swift.Toolchain`）+ SwiftPM（Swift Build，默认后端）构建 `NetNewsWireCore.dll`。
- .NET 10 + WinAppSDK 2.7，打包为 MSIX，同时提供 unpackaged 版。
- GitHub Actions `windows-latest`：先构建 Swift，再构建 .NET，然后跑测试。
- **Linux 作为廉价代理**：Linux 和 Windows 都使用 swift-corelibs-foundation 加新的 swift-foundation，核心模块先做到 `swift build && swift test` 在 Linux 上通过，能提前暴露大部分 Apple 专有依赖。

## 4. M0 结果（2026-11-26，已通过）

环境：Windows 11（26300），Swift 6.4.3（M0 时为 Scoop，现为官方安装器），VS 2022 Build Tools（MSVC 14.44，Windows SDK 10.0.26100），.NET 10.0.404，Windows App SDK 2.7.0。

`NetNewsWire.exe --selftest https://netnewswire.blog/feed.xml <report.json>` 的结果：

| 检查项 | 结果 |
|---|---|
| Swift 核心 DLL 被 .NET 加载，`@c` 函数可调用 | ✅ |
| UI 线程就是 Swift 主线程 | ✅ |
| `URLSession` + `FoundationXML` 下载并解析订阅源 | ✅（25 条） |
| `@MainActor` 回调运行在 UI 线程上 | ✅ |
| C# `await` 的后续代码回到 UI 线程 | ✅ |
| WebView2 渲染文章 | ✅ |

其他发现：
- DLL 只导出了 6 个 `@c` 符号。窄门面让 65535 导出符号上限不再是问题。
- **Scoop 安装的 Swift 与 Swift Build（6.4 的默认构建系统）不兼容**：Scoop 去掉了版本目录，Swift Build 推断出的工具链路径因此错误；用 junction 也绕不过去，因为 Swift Build 会解析出真实路径。已改用官方安装器（`winget install Swift.Toolchain`），Swift Build 正常工作。注意卸载 Scoop 版 Swift 时会删掉用户级 `SDKROOT`，需要重新设置。
- 从 WSL 的 UNC 路径构建不可靠，应在 Windows 本地目录中构建。

## 4.1 M1 进展（2026-11-27：Windows 上全部核心模块测试通过）

各模块在 Windows 上 `swift test` 的结果：

| 模块 | 结果 |
|---|---|
| RSCore | ✅ XCTest 27、Swift Testing 61（含 WIC 图像层：8 种 EXIF 方向、多帧、缩放、PNG/JPEG/TIFF 编码、亮度）。`CollapsingWhitespacePerformanceTests` 的测量波动在这台机器上一直是 15–20%，超过 XCTest 默认的 10% 上限，不是功能问题 |
| RSParser | ✅ 361（一个性能测试在负载高时偶尔超时） |
| RSDatabase | ✅ 13（含 11 个 FMDB 兼容性测试，Apple 平台上也跑同一组，对照 ObjC FMDB） |
| RSWeb | ✅ 25 |
| Articles / ArticlesDatabase / SyncDatabase | ✅ 6 / 24 / 4 |
| FeedFinder / NewsBlur | ✅ 4 / 1 |
| Account | ✅ XCTest 89、Swift Testing 39 |
| Images | ✅ 36（缩略图按 EXIF 方向解码、取最大帧、按显示高度缩放、正方形从顶部保留裁剪、灰度图标） |
| Secrets、HTMLMetadata、ErrorLog、ActivityLog、RSTree | ✅ 编译通过（没有测试目标） |

M1 中发现并修掉的问题（都只在非 Apple 平台上出现）：
- `AppConfig.dataFolder` 在 Windows/Linux 上的初始化器引用了自己（两个 `#if` 分支都不匹配，局部变量没声明），一次性初始化等待自己，测试挂死。现在 Windows 用 `%LOCALAPPDATA%\NetNewsWire`，缓存放在其下的 `Caches`。
- `Thread.isMainThread` 断言与 `BatchUpdate` 的 `DispatchQueue.main.sync` 自死锁，见 §3.2。
- 没有显式 `import Foundation` 的文件（Apple 上靠 AppKit/UIKit 间接导入）在 Windows 上会把 `extension Notification.Name` 加到 FoundationEssentials 的类型上，别的文件看不到这些通知名。
- swift-corelibs-foundation 不会在自定义 `URLProtocol` 看到请求之前合并 `httpAdditionalHeaders`，用 `URLSession.requestWithAdditionalHeaders(_:)` 统一行为。

M1 遗留：`SecretKey.swift` 的生成已在 M2 加进 `Windows/build.ps1`（见 §4.2）；CI 上跑 Windows 测试仍待做。

**Apple 平台需要验证**：Package.swift 用 `#if os(macOS) || os(iOS)` 让 Apple 平台的配置保持原样，但以下改动在 Mac 和 iOS 上也会编译，需要在 Mac 上用 Xcode 跑一遍 `buildscripts/build_and_test.sh`：`CoalescingQueue` 的重写；selector 观察者改为闭包（`addObserver`/`addMainActorObserver`，约 60 处）；`Thread.isMainQueue`；Account、Images 调用点的修改；各处的条件导入。

## 4.2 M2 结果（2026-11-27：本地账户门面 API 打通）

`Windows/Core` 拆成两层：`CoreService`（门面，JSON 进出，可测试）和 `NetNewsWireCore`（把它导出到 C ABI，见 §3.1）。C# 侧 `SwiftCore` 给每个方法提供强类型包装，事件通过 `SwiftCore.EventReceived` 在 UI 线程上发出。

| 方法 | 作用 |
|---|---|
| `core.info` | 版本、数据目录 |
| `sidebar.get` | 智能订阅源（今天、全部未读、星标）、账户、文件夹、订阅源及未读数 |
| `articles.fetch` | 按选择（today/unread/starred/feed/folder/search）取时间线摘要，默认最新在前，可指定 `sort`、`groupByFeed`，可限制条数 |
| `articles.sort` | 把给定的文章按排序重排，返回引用（时间线改排序时用，和 Mac 一样重排已显示的行） |
| `article.get` | 单篇文章详情（HTML、链接、作者、日期、状态） |
| `articles.mark` | 跨账户标记已读/星标 |
| `feeds.subscribe` / `feeds.delete` / `feeds.rename` / `feeds.move` | 订阅（会先验证订阅源）、删除、重命名、移动 |
| `folders.add` / `folders.rename` / `folders.delete` | 文件夹 |
| `opml.import` / `opml.export` | OPML，与 Mac/iOS 导出的文档相同 |
| `refresh.all` | 刷新全部账户，返回是否执行（断网时跳过）和错误列表 |

验证：
- `Windows/Core` 的 `swift test`：10 个测试全部通过，不访问网络（文章由测试解析一段 RSS 后直接写入数据库）。
- `NetNewsWire.exe --selftest https://netnewswire.blog/feed.xml <report>`：订阅、刷新（25 篇）、标记已读再恢复、未读数、WebView2 渲染、`notFound` 错误、五种事件全部到达；回调和 `await` 的后续代码都在 UI 线程上。
- 自测用临时的 `LOCALAPPDATA` 运行，不碰用户数据。

这一轮发现的问题：
- **没有控制台的 GUI 进程里写 stderr 会崩溃**：`FileHandle.write(_:)`（不抛错的旧 API）在 swift-corelibs-foundation 里写失败时直接陷入。非 Apple 的 `Logger` 改用 `write(contentsOf:)` 并忽略错误。M0 的自测没有日志输出，所以当时没暴露。
- 单元测试曾把 `AccountManager.shared` 的数据写进真实的 `%LOCALAPPDATA%\NetNewsWire`。现在非 Apple 平台上运行单元测试时，`AppConfig` 的数据目录和缓存目录，以及 `Platform.dataSubfolder`（主题目录用它，M3 时发现漏了），都改到同一个每个测试进程独立的临时目录（`Platform.unitTestDataFolder`）。
- `build.ps1` 用 gyb 生成 `SecretKey.swift`：优先用 PATH 里的 Python（跳过 Microsoft Store 的占位程序），否则用 Swift 安装器自带的嵌入式 Python 3.10。嵌入式 Python 的 `._pth` 不把脚本所在目录加进 `sys.path`，所以直接运行 `gyb.py`。查找 `*.gyb` 时跳过 `.build`（SwiftPM 检出的 swift-crypto 里也有）。
- OPML 导入不会使用 `htmlUrl` 作为主页地址，主页在第一次刷新时从订阅源本身取得。各平台一致，保持不变。

M2 中有意没做、留给后续的：
- 文章页仍用临时的 HTML 模板。Mac/iOS 的文章渲染（`Shared/Article Rendering`，模板和主题）在 Xcode 目标里，依赖 Images 和主题管理。M3 计划把这部分以及 `Shared/` 中与 UI 无关的逻辑（智能订阅源、文章工具函数、OPML 导出）移进一个三端共用的模块，而不是在 Windows 上复制一份。目前门面里复制的几处都很小（链接选择、显示日期、OPML 外壳），并注明了出处。
- 同步账户的添加与认证（M4）、定时刷新与通知（M5）。

## 4.3 M3 进展（2026-11-27：共享文章渲染、三栏界面、图标、主题、缩略图、拖放、无障碍）

**新模块 `Modules/ArticleRendering`**（Mac、iOS、Windows 共用）：
- 内容：渲染核心 `ArticleHTMLRenderer`（从 `Shared/Article Rendering/ArticleRenderer.swift` 移出）、特例处理、附件与主媒体、标题净化 `ArticleTitleSanitizer`、主题模型 `ArticleTheme`/`ArticleThemePlist`，以及资源 `core.css`、`stylesheet.css`、`template.html`、`main.js`、`newsfoot.js`。
- 应用设置（文字大小、缩略图路由、阅读器视图的提取内容、本地化的 “Link:”）通过 `ArticleHTMLRenderer.Options` 传入，模块本身没有设置。
- `Shared/Article Rendering/ArticleRenderer.swift` 保留原来的 API，变成适配层，Mac/iOS 的调用点不用改；`ArticleStringFormatter.sanitizedTitle` 转发到模块。平台相关的 `page.html`、`blank.html`、`main_mac.js`、`main_ios.js` 和 WebKit 部分仍在各自应用里。
- 文章的链接与日期辅助（`preferredLink`、`logicalDatePublished` 等）从 `Shared/Extensions/ArticleUtilities.swift` 移到 Articles 模块，成为公开 API；门面里原来复制的几处随之删除。
- 原来在应用测试目标里的 5 个渲染测试文件移到模块（`ArticleRenderingTests`，加上新的端到端渲染测试，共 74 个），Windows 上全部通过，也加进了 `NetNewsWire.xctestplan`。
- Xcode 工程：按 Images 模块的手工接线方式，把 `ArticleRendering` 产品加到 Mac 和 iOS 应用目标（链接和嵌入）。`Shared` 是同步文件夹组，移走的文件自动退出目标。**需要在 Mac 上用 Xcode 构建验证。**

**Windows 文章页**：门面新增 `article.render`、`article.renderMessage`、`article.scripts`。WebView2 在文档创建前注入核心提供的 `main.js`、`newsfoot.js` 和 Windows 自己的 `main_windows.js`（对应 `main_mac.js`：滚动、链接悬停、快捷键转发），再加载渲染好的页面。点击的链接用默认浏览器打开。
- Windows 的 `page.html` 和 Mac 的一样不带 doctype。默认样式表的文字大小选择器（`.xlargeText`）和 Mac 代码给的类名（`xLargeText`）大小写不一致，靠怪异模式下类名不区分大小写才生效。这是 Apple 侧已有的问题，这里先保持一致，没有改。
- 主题用的是 Apple 字体名（`-apple-system`、`ui-monospace`、`Menlo`）。Windows 页面用 `@font-face` 把它们映射到 Segoe UI 和 Cascadia Mono/Consolas，主题的字体选择仍然有效。不这样做时，Chromium 会退回到系统区域的默认字体，在中文或日文系统上把拉丁标点画成全角。
- 本地账户在 Windows 上叫 “On This PC”。原来的名字取自 Apple 应用包里按设备区分的字符串表，Windows 上没有，界面会直接显示键名 `account.name.on-my-device`。

**三栏界面**（WinUI 3，CommunityToolkit.Mvvm 8.4 视图模型 + CommunityToolkit.WinUI.Controls.Sizers 分隔条）：
- 侧栏是 `TreeView`，包括智能订阅源、账户、文件夹、订阅源和未读数；核心发来变化时按键原地更新，选中和展开状态不丢。
- 时间线显示未读点、星标、标题、摘要、订阅源名和日期；内容变化时原地合并，和 Mac 一样，读过的文章在切换选择前不会从“全部未读”里消失。
- 自定义标题栏里放搜索框；工具栏有刷新、添加订阅源（会读取剪贴板里的 URL）、新建文件夹、全部标为已读、已读/未读、星标、下一篇未读、在浏览器中打开、导入/导出 OPML。侧栏右键菜单可以重命名、删除、打开主页、全部标为已读。
- 快捷键与 Mac 的 `GlobalKeyboardShortcuts.plist` 一致：Space（先滚动文章，到底再跳到下一篇未读）、N/+、-、R/U、S、K、M、L、B/Enter，另有 Ctrl+R、Ctrl+N、Ctrl+Shift+N、Ctrl+K、Ctrl+F。WebView2 是独立窗口，按键收不到，所以由 `main_windows.js` 转发。启动时焦点放在时间线上（时间线为空时放在侧栏），不让标题栏的搜索框抢走焦点。
- 自测在应用内驱动界面：检查启动焦点，按 N 选中并显示第一篇未读且标为已读，按 R 切回未读，以及页面里的主题标题和脚本。截图用 UI 自动化选中文章，不依赖前台窗口。

**订阅源图标与头像**：
- 选图标的逻辑（订阅源图标 → 主页图标 → favicon → 生成的图标，加载中显示上次找到的那个；作者头像优先）从 `Shared/IconImageCache.swift` 移到 Images 模块的 `FeedIconResolver`，`IconImageCache` 改为调用它，Windows 门面也用它。
- 门面新增 `icons.feed`、`icons.article`（PNG，附带明暗判断）和 `iconsChanged` 事件。生成图标用的模板是从 Mac 的 `faviconTemplateImage.pdf` 渲染的 144px PNG（WIC 不读 PDF），NetNewsWire 自己的订阅源图标直接用 Mac 资源里的 PNG。
- 侧栏和时间线显示图标，按订阅源共享缓存；文章页顶部的 `nnwImageIcon:` 请求由 WebView2 的自定义方案（`WebResourceRequested`）提供。Chromium 会把方案名转成小写，所以注册和过滤都用小写。为了注册自定义方案，WebView2 环境改为显式创建，用户数据放在 `%LOCALAPPDATA%\NetNewsWire\WebView2`，不放在 exe 旁边。
- 自测用 Daring Fireball 验证真实下载：favicon 下载后经 WIC 解码、缩放到 48×48，文章页图标也能加载。

**主题与文字大小**：
- 门面新增 `themes.list`、`themes.install`、`themes.delete`；渲染请求带上主题名和文字大小。查找规则和 Mac 的 `ArticleThemesManager` 相同：默认主题，加上随应用发布的主题（仓库的 `Themes/`，复制到 exe 旁边），加上用户安装在数据目录 `Themes` 里的主题，按名字不区分大小写排序。
- 设置由 Windows 应用自己保存（`%LOCALAPPDATA%\NetNewsWire\Settings.json`），每次请求时传给核心，核心不保存界面状态。设置对话框（Ctrl+,）可以选主题、安装或删除主题、调文字大小；Ctrl+= / Ctrl+- 调文字大小，对应 Mac 的 Cmd-+/-。修改后立刻重新渲染当前文章。
- 自测检查：找到 11 个主题；切到 Sepia 后页面背景是 Sepia 的纸色；文字大小类名生效。

**时间线缩略图**：
- 和 Mac 时间线的路径相同：`ArticleThumbnailFinder` 选图（`articles.fetch` 带 `thumbnailMode` 时，先在后台解析文章 HTML，再给每篇文章填上 `thumbnailURL`），`ThumbnailDownloader` 在后台按显示尺寸下载、解码（WIC），最新的优先。`thumbnails.get` 立刻返回：已解码的 PNG，或者“等待中”并启动下载；就绪或失败换图时发 `thumbnailsChanged`。
- 只为显示出来的行请求缩略图（`ListView.ContainerContentChanging`），和 Mac 一样，快速滚动时不会排队一堆已经滚走的下载。小图在文字右边，从顶部裁成正方形；大图在文字下面，按比例缩放进 180 高的框。设置里可以选“无/小/大”，默认无（和 Mac 一样）。
- 自测：NetNewsWire 博客的 4 篇文章有缩略图，其中一张真实下载并解码为 256×256。

**深色图标的背景板**：和 Mac 的 `IconView` 规则一致：生成的图标不加；深色模式下深色图标、浅色模式下亮色图标加半透明背景（对应 `tertiarySystemFill`），主题切换时重算。

**拖放整理订阅源**：侧栏里只能拖订阅源。TreeView 会先在自己的集合里移动节点，放下后转成核心的 `feeds.move`（拖到文件夹 = 移进去，拖到账户 = 移到顶层，其他位置 = 不动），再按核心的结构重新同步，非法的放置自然被撤销，展开和选中状态保留。自测通过同一条路径验证移动结果；鼠标拖拽手势本身还没有自动化验证。

**无障碍（UI 自动化树检查）**：所有按钮、搜索框、侧栏项、时间线项都有名字；时间线项读作“未读、星标、标题、订阅源、日期”；侧栏项带未读数（“All Unread, 18 unread”，和 Mac 上 VoiceOver 读的一致）。TreeView 的名字设在外层控件上不会传到 UI 自动化看到的内层列表，改为在加载后给内层列表命名。

这一轮发现的问题：`AppSettings.Current` 是静态属性初始化器，排在它后面声明的静态数组在 `Load` 运行时还是 null，所以缩略图设置被当成无效值丢掉了。改为延迟初始化。

**时间线排序与分组**：Mac 的排序代码（`ArticleSorter`、`ArticleSortKey`、`ArticleSortParameters`）移进 Articles 模块，Windows 和 Mac 用同一份；各平台只提供“时间线上显示的订阅源名和标题”这两个闭包。Mac 端 `Shared/Timeline/ArticleSorter.swift` 和 `ArticleSortParameters.swift` 变成适配层（默认闭包、本地化的菜单名），调用方不变；`ArticleSorterTests` 移到 `Modules/Articles/Tests`，在 Windows 上 16 个全过。核心：`articles.fetch` 接受 `sort`（`{key, ascending}`）和 `groupByFeed`（只对日期排序有效，和 Mac 一样）；新增 `articles.sort`，把当前显示的行按新排序重排——Mac 改排序时是重排已显示的行，所以已读后仍留在“全部未读”里的文章不会消失。界面：工具栏“排序”菜单，字段、按字段措辞的方向（“Newest Article on Top”/“A to Z”/“Ascending”）、Group by Feed，第一次选某字段用 Mac 的默认方向；设置保存在 `Settings.json`；重排后保留选中和正在显示的文章。自测：按标题排序后顺序正确、选中和文章页保留、行数不变，菜单在两种状态下的勾选和禁用都正确。

**订阅源“获取信息”**：和 Mac 的订阅源检查器一样：图标、可编辑的名称（空名称忽略，不会清掉名字）、主页（带“打开”）、订阅源 URL（带“复制”）。侧栏右键菜单和 Ctrl+I（Mac 上是 Cmd-I）打开。Mac 检查器里的“新文章通知”和“总是用阅读器视图”两个开关暂时没放：Windows 上还没有通知（M5）和阅读器视图，放一个没有作用的开关会误导用户。自测通过对话框真实的“保存”按钮（UI 自动化调用）改名并验证侧栏结果。

**拖入链接添加订阅源**：和 Mac 侧栏一样，把链接拖到侧栏会打开“添加订阅源”对话框，URL 和拖放位置的文件夹（拖到文件夹 = 该文件夹，拖到订阅源 = 它所在的文件夹，其他 = 顶层）已经填好。接受 http/https 和浏览器交给阅读器的 `feed:` URL（`feed:https://…`、`feed://…`），剪贴板预填也用同一规则。TreeView 自己处理拖动排序，所以外部拖放的处理器用 `handledEventsToo` 注册，并在内部拖动订阅源时让开。自测验证 `feed:` 链接、目标文件夹和非链接文本被忽略；从浏览器真实拖动的手势还没有自动化验证。

还没做：
- 阅读器视图（依赖 `Shared/Article Extractor`，需要 Mercury API key）。
- 用真实的 Narrator 走一遍（目前只检查了 UI 自动化树），以及高对比度主题下的检查。
- 从浏览器真实拖入链接、在侧栏里真实拖动订阅源的手势验证（目前只验证了放下之后的逻辑）。
- Windows 上 `.xcstrings` 不会被编译（Swift Build 没有对应规则），模块里的本地化字符串只能退回英文键。需要在构建时转换，或者等工具链支持。

## 4.4 技术路线复核与网络传输（2026-11-27）

按“每个方案都要调研、选最前沿”的要求，对已有决策和后续路线做了一轮复核。

**仍然成立的决策**
- 路线 B（Swift 核心 + C#/WinUI 3）：Swift 直接驱动 WinUI 的预编译绑定已归档、固定在 WinAppSDK 1.7 且只有 x64，swift-winrt 自己声明还不能对外使用；.NET 的 Swift 互操作（`CallConvSwift`）在 .NET 10 仍然只支持 Apple 平台。C ABI 仍是唯一受支持的桥。WinUI 3 是“只做 Windows、要现代 Fluent 界面”的推荐框架；Windows App SDK 2.7.0（2026-11-17）是最新稳定版，项目已在用。
- 凭据：Credential Manager（DPAPI）就是 Windows 的系统凭据库，`PasswordVault` 是同一存储的 WinRT 包装，没有更好的选择。
- 图片：WIC 是系统图像栈（硬件解码、EXIF、格式扩展都走它）。

**后续路线的选择**
- M5 打包：MSIX。有包标识才能干净地注册 `netnewswire:` 协议（Feedly 的 OAuth 客户端回调地址固定是 `netnewswire://auth/feedly`，换不成 loopback）、使用应用通知、走 Store 或 `.appinstaller` 更新。未打包的退路是 Velopack，但社区报告未打包、自包含时 `AppNotificationManager.Register()` 会抛异常（WindowsAppSDK#6774），需要实测。
- M4 OAuth：RFC 8252 推荐 loopback；但 Feedly 客户端注册的是自定义 scheme，所以走“系统浏览器 + 协议激活 + 单实例重定向（`AppInstance.FindOrRegisterForKey` / `RedirectActivationToAsync`）”，加 PKCE 和 state 校验（核心里已有 state）。

**网络传输：从 URLSession 换成 WinHTTP**

SwiftNIO / AsyncHTTPClient 仍然不能在 Windows 上编译（swift-nio-ssl 不支持 Windows SDK），所以可选的只有 swift-corelibs-foundation 的 URLSession（libcurl + libdispatch 套接字循环）、WinHTTP，或者把 HTTP 交给 C# 的 HttpClient。在本机实测（同一台机器，同一批地址）：

| 测试 | URLSession（libcurl） | WinHTTPClient |
|---|---|---|
| 下载 25 MB（CPU 时间） | 3.48 s（墙钟 4.58 s，一个核占满） | 0.17 s（curl.exe 为 0.14 s） |
| 30 个真实订阅源并发，冷启动 | 18.8 s，7 个超时，CPU 2.25 s | 2.7 s，0 失败，CPU 0.12 s |
| 同上，热（两轮） | 1.8–2.0 s，CPU 2.5–3.0 s | 1.5–2.6 s，CPU 0.03–0.14 s |
| 上传 16 KB–1 MB | 成功（报告中 >64 KB 卡死的问题在本机 x64 上没有复现） | 成功，CPU ≈ 0 |

URLSession 的问题和社区报告一致：传输期间 libdispatch 循环忙等，冷启动时超时，并且不读系统代理。HttpClient 也能解决，但会让核心依赖宿主进程、核心测试离不开 C#。WinHTTP 是系统 HTTP 栈：异步完成回调、用户的代理设置（`WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY`）、Schannel 和系统证书库、HTTP/2（Google、GitHub、netnewswire.blog 实测协商到 HTTP/2），系统支持时也请求 HTTP/3，自动解压 gzip/deflate。

实现要点：
- `URLProtocol` 子类不可行：swift-corelibs-foundation 里自定义协议报告重定向是 `fatalError`，而 `DownloadSession` 依靠重定向回调做永久重定向缓存、`didFollowRedirectFor` 和特例 User-Agent。所以重定向由 `WinHTTPClient` 自己跟随（WinHTTP 设为不跟随），每一步交给 `willRedirect` 处理器；303 以及 POST 后的 301/302 改为 GET，跨主机时去掉 Authorization。
- `DownloadSession` 在 Windows 上用自己的下载记录代替 `URLSessionTask`，按 URLSession 代理方法的同样顺序调用同样的逻辑（4xx/429 节流、进度、委托回调）；被 4xx 或委托中止的下载不再回调完成，和 URLSession 一致。
- 和所有 NetNewsWire 会话的配置一致：关闭 cookie 处理（请求自带的 Cookie 头照常发送，NewsBlur 需要）、每个服务器一个连接（HTTP/2 在其上多路复用）、订阅源 15 秒/60 秒超时。错误映射成 URLSession 用的 `URLError` 代码。
- 验证：RSWeb 31 个测试（新增 6 个：重定向规则、原始响应头解析、错误码映射），Account 模块测试全部通过；探针验证重定向回调、拒绝重定向、gzip、304、TLS 失败（-1200）、未知主机（-1004）、取消（-999）、整体超时（-1001）；应用自测通过 WinHTTP 完成订阅、刷新（无错误）、图标、缩略图。

## 4.5 M4 进展（2026-11-27：同步账户，第一批）

- **核心方法**：`accounts.types`、`accounts.add`、`accounts.delete`、`accounts.setActive`（`CoreService+Accounts.swift`）。添加流程和 Mac 的账户表单一步一步对应：先向服务验证凭据，再查重复，再创建账户、保存凭据（Windows Credential Manager），然后开始刷新。Reader API 和 NewsBlur 同时保存密码和换来的令牌（令牌过期时重新登录），和 Mac 一样。
- **可添加的服务**：和 Mac、iOS 的开发版一致，`isDeveloperRestricted` 的服务（Feedbin、Feedly、Inoreader）不提供，因为它们需要 NetNewsWire 的 API 协议或密钥。目前提供 BazQux、FreshRSS、Miniflux（用户名密码或 API 令牌）、NewsBlur、The Old Reader。正式版有了密钥以后放开；Feedly 还需要 MSIX 包标识注册 `netnewswire:` 协议（见 §4.4）。
- **界面**：命令栏溢出菜单里的“Accounts…”：每个账户一个复选框（停用后不显示、不刷新）、同步账户的删除（二次确认，只删本机数据）、“Add Account…”打开添加对话框（服务、按服务显示的 API URL / 用户名密码 / 令牌、注册链接）。登录失败时对话框保持打开并显示错误，和 Mac 的表单一样。
- **测试数据隔离**：单元测试运行时，Windows 的 `CredentialsManager` 把凭据放在内存里，不写用户的 Credential Manager（和数据文件夹用临时目录同理）。已确认之前的测试没有留下任何 `NetNewsWire/` 凭据。
- **错误信息**：swift-corelibs-foundation 的 `URLError` 没有本地化描述，界面上会显示“NSURLErrorDomain error -1004”。WinHTTP 传输层给每种错误补上 Apple Foundation 的原文措辞。
- **验证**：核心 17 个测试（新增：服务列表不含受限服务；FreshRSS 通过 `TestingURLProtocol` 模拟登录，验证缺参数、受限服务、401、成功添加、端点和两种凭据、重复、停用、删除后凭据清除、默认账户不能删除）。应用自测：添加对话框列出 5 个服务，向不存在的服务器登录时显示错误、对话框保持打开、没有创建账户。

**真实服务器同步验证（本机 Docker 运行的 FreshRSS）**：应用的 `--selftest-sync` 模式（服务器和凭据从环境变量传入，不出现在命令行）添加账户、等首次同步、在应用里把一篇文章标为已读并加星、再同步，然后删除账户。结果：
- 服务器 → 应用：三个订阅源和未读数与服务器完全一致（10 / 25 / 0，其中 xkcd 是先在服务器上全部标为已读的）。
- 应用 → 服务器：通过 Google Reader API 直接查询服务器，那篇文章已加星，NetNewsWire 的未读数同步减一；连续运行时每次都从服务器上一次的结果开始（20 → 19 → 18 → 17）。
- 删除账户后 Credential Manager 里没有残留，真实数据文件夹不受影响。

**退出时崩溃（这轮发现并修复）**：同步过程中退出，WinUI 的 `CoreMessagingXP.dll` 抛出 0xC000027B（0x800710DD：调度器已关闭后仍向它派发工作）。原因是核心还在后台工作，不断向 UI 线程投递主队列任务和事件。修复和 Mac 的 `applicationWillTerminate` 对应：新的核心方法 `app.prepareToQuit` 先停止事件、保存、把未发送的已读/星标状态发出去（最多等 2 秒），然后 C# 端 `SwiftCore.Shutdown()` 停止转发事件、响应和主队列任务，最后才退出。关闭主窗口和自测都走 `App.QuitAsync()`。修复前同一个场景间歇崩溃，修复后连续多次退出码为 0。

## 4.6 没有 Mac 时的 Mac/iOS 验证

仓库自带的 GitHub Actions CI（macos-26 运行器、Xcode 26.6：SwiftLint 严格模式、macOS 与 iOS 测试计划、警告即错误）在 fork（`wianger/NetNewsWire`，`windows-port` 分支，fork 内的 PR）上运行，不向上游提交任何东西。本地先用 Docker 里的 SwiftLint 0.65 按同样规则检查改动的文件。

第一轮 CI 发现两个问题，都是只在 Apple 平台上才会出现的：
- Swift 版 FMDB（Windows/Linux 用）的方法名必须与 Objective-C FMDB 在 Swift 里的导入名一致：`rs_rowExistsWithValue:forKey:tableName:` 导入为 `rs_rowExists(withValue:forKey:tableName:)`，`rs_selectColumnWithKey:tableName:` 导入为 `rs_selectColumn(withKey:tableName:)`。共享的测试按 Apple 的名字调用。
- `addMainActorObserver` 里多余的 `nonisolated(unsafe)`（Apple 编译器警告，CI 把警告当错误）。

另外，CI 用的测试计划 `NetNewsWire-CI.xctestplan` 补上了 ArticleRenderingTests。

## 4.7 M5 进展（2026-11-27：打包、Swift 运行时、单实例与 URL）

**Miniflux 真实服务器同步**：本机 Docker 运行 Miniflux 2.3.5 + PostgreSQL 17，用户名密码和 API 令牌两种登录都通过 `--selftest-sync` 验证：分类成为文件夹（All、Tech），未读数与服务器一致（含先在服务器上标为已读的 xkcd），应用里的已读/星标发到服务器，令牌那次从密码那次留下的状态开始。FreshRSS 和 Miniflux 都已对真实服务器验证。

**调研结论**
- Swift 运行时：Windows 上静态链接仍是实验性 SDK 的可选路径，且仍需 `dispatch.dll`、`BlocksRuntime.dll`；稳妥的做法是把运行时 DLL 随应用一起分发。
- 单实例与协议：Windows App SDK 的 `AppInstance.FindOrRegisterForKey` + `RedirectActivationToAsync` 是官方做法；协议注册放在 MSIX 清单里最干净。
- 打包与签名：单项目 MSIX（MSBuild）；微软新的 `winapp` CLI（公开预览，v0.8）能生成开发证书、打包、签名并支持 Azure Trusted Signing。已从微软官方 GitHub 发布下载并确认签名有效，但在本机运行它被权限检查拦下，所以目前用 MSBuild 的单项目打包。

**随应用分发 Swift 运行时**：`build.ps1` 从核心 DLL 出发，用 `dumpbin /dependents` 沿着导入表找出运行时文件夹里真正用到的 DLL，复制到 `App/obj/SwiftRuntime/<平台>`，应用项目再拷到 exe 旁边。结果是 36 个运行时 DLL 里的 19 个（59 MB，其中 ICU 36 MB），包括 Swift 依赖的 VC++ 运行时；FoundationXML、Swift 测试和正则构建库等没用到的不带。验证：把所有 Swift 路径从 PATH 里去掉后，应用自测全部通过。

**单实例与打开 URL**：`Program.Main` 按数据文件夹生成实例键（同一个数据库只能被一个进程打开），后启动的实例把激活（MSIX 的协议激活，或未打包时命令行上的 URL）转交给正在运行的实例后退出。URL 的含义由核心按 Mac 的 `getURL` 处理逻辑决定（`app.interpretOpenedURL`）：`feed:`、`feeds:`、`x-netnewswire-feed:` 和网页地址规范化后打开“添加订阅源”；`netnewswire://theme/…` 是主题（Windows 上暂时提示先下载再安装）；其他 `netnewswire:` 地址忽略（以后给 Feedly OAuth 回调用）。注意：转交过来的 `Arguments` 是整条命令行，开头是 exe 路径，需要先去掉。自测：第二个进程带 `feed:https://xkcd.com/atom.xml` 启动后立即以 0 退出，第一个进程打开了添加订阅源，地址为 `https://xkcd.com/atom.xml`。

**MSIX 包**：`build.ps1 -Package` 生成未签名的 MSIX（`App/Package.appxmanifest`）：开发用的包标识，Mac 应用图标生成的整套 Windows 徽标和多尺寸 `.ico`，Mac 注册的四个协议（`netnewswire`、`feed`、`feeds`、`x-netnewswire-feed`），`internetClient` 和 `runFullTrust`。包大小从 127 MB 降到 69 MB：
- Windows App SDK 1.8 起元包还带 AI、ML、Search、Widgets 组件（其中 ONNX Runtime 和 DirectML 三种架构共约 80 MB）。不能改成只引用组件包：CommunityToolkit 的 WinUI 包依赖元包，会被解析成 1.6，进而破坏 MSIX 工具的 `CustomBeforeMicrosoftCommonTargets` 导入链。做法是保留元包，对 AI、ML、Search、Widgets 和 `Microsoft.Windows.AI.MachineLearning` 直接引用并 `ExcludeAssets="all"`。
- 按平台设置 `RuntimeIdentifier`，只带一种架构的原生文件。
- 精简后应用自测、无 Swift 的 PATH 下自测、单实例转交都通过。

**签名**：用户允许后改用 `winapp` CLI（每次运行都设置 `WINAPP_CLI_TELEMETRY_OPTOUT=1`，不发送使用数据）：`winapp cert generate` 从清单读出发布者生成 90 天的自签名开发证书（随机密码，不用公开的默认密码；证书和密码放在仓库外），同时导出只含公钥的 `.cer`；`winapp sign` 给 MSIX 签名。信任这个证书需要管理员权限（UAC），由用户执行；安装选的是“信任一个证书”而不是“开发者模式”：前者只在一个证书存储里加一项，可以撤销，也覆盖了正式发布需要的签名环节；后者会放宽整个系统对未签名应用的限制。

**新文章通知**：和 Mac 的 `UserNotificationManager` 一致：只为“新文章通知”打开了的订阅源里的新的未读文章发通知，文章标为已读时撤回通知。核心：`FeedInfo.notifiesAboutNewArticles`、`feeds.setNotifications`，事件 `newArticles`（附带订阅源名、标题、摘要）和 `articlesRead`（被标为已读的文章 ID）。应用：Windows App SDK 的 `AppNotificationManager`，通知带“标为已读”和“加星标”按钮；点击通知打开文章所在的订阅源并选中文章；应用没运行时点击通知会以 AppNotification 激活启动，和其他激活一样经单实例转交。获取信息里加了 Mac 的“新文章通知”复选框。
- 通知按标签（文章 ID 的哈希；标签最长 64 字符）标识，不设分组：Windows 通知的身份是“标签 + 分组”，而撤回时只知道文章 ID。
- 这轮发现的问题：核心的事件合并按固定顺序发出各类事件，新加的事件类型没放进顺序表就会被悄悄丢掉。现在加了断言：每种事件类型都必须在顺序表里。
- 验证：核心测试（默认关闭时不通知；打开后通知；标为已读后撤回；已读文章不通知），应用自测在未打包的应用里真实显示通知、模拟点击选中文章、标为已读后通知消失。未打包应用注册通知会在用户配置里按 exe 路径写注册信息，自测结束时会注销。

**安装验证（用户信任了开发证书之后）**：`Add-AppxPackage` 为当前用户安装，签名有效。通过 `shell:AppsFolder` 启动（和开始菜单一样），进程从 `WindowsApps` 下的包目录运行，带包标识。数据被 Windows 重定向到包自己的目录（`%LOCALAPPDATA%\Packages\<包系列名>\LocalCache\Local\NetNewsWire`），用户真实的 `%LOCALAPPDATA%\NetNewsWire` 启动前后都不存在。应用运行时打开 `x-netnewswire-feed:https://xkcd.com/atom.xml`（只有本应用注册的协议，不会被别的阅读器接走），由清单里的协议声明激活并转交给正在运行的实例（仍然只有一个进程），打开了添加订阅源，地址为 `https://xkcd.com/atom.xml`。关闭窗口后走正常退出流程。

**定时刷新**：Mac 的两个计时器（`Shared/Timer`）用 Objective-C 的选择器，不能共享，于是在核心里用 Swift 并发按同样的规则重写（`CoreService+Timers.swift`）：账户按用户设置的间隔刷新（手动、30 分钟、1/2/4/8 小时，默认 2 小时，启动时先刷新一次），状态每 2 分钟同步一次，没事可做时退到 30 分钟，一有状态变更排队就回到 2 分钟。按墙上时钟判断是否到期（每分钟至少看一次），电脑睡眠错过的刷新醒来后很快补上。设置里加了“刷新订阅源”。自测运行时不在启动时刷新（自测自己刷新）。核心测试覆盖了间隔、手动、立即刷新和空闲退避。

还没做：正式签名和更新渠道（Azure Trusted Signing、`.appinstaller` 或 Store）、后台刷新、ARM64 构建（需要 ARM64 的 Swift 运行时）。

## 5. 里程碑

1. ~~**M0 Spike**~~ ✅ 已完成（见 §4）：一个最小 `@c` DLL 加 WinUI 3 壳，验证加载、回调、`@MainActor` 执行、异步刷新和 WebView2 渲染一篇文章。
2. **M1 核心可移植**：FMDB 替换、Logger shim、Secrets 协议化、CloudKit 隔离；Linux 上 `swift test` 全绿，然后 Windows 上同样全绿。
3. ~~**M2 门面 API**~~ ✅ 已完成（见 §4.2）：本地账户的 OPML 导入导出、刷新、时间线、已读/星标、订阅源与文件夹管理。
4. **M3 WinUI 三栏 UI**：侧栏、时间线、WebView2 详情页、主题、快捷键、Narrator 测试。
5. **M4 同步账户**：Feedbin、Feedly（OAuth 走系统浏览器 + loopback）、NewsBlur、Reader API、Miniflux。
6. **M5 平台集成**：Toast 通知、后台刷新、`feed:` 协议关联、MSIX 打包与自动更新、ARM64。

## 6. 参考资料
- Swift 6.3 发布：https://swift.org/blog/swift-6.3-released/
- Swift 6.4 发布：https://www.swift.org/blog/swift-6.4-released/
- Windows Workgroup：https://www.swift.org/blog/announcing-windows-workgroup/
- SE-0495 `@c`：https://forums.swift.org/t/accepted-se-0495-c-compatible-functions-and-enums/82833
- Custom Main and Global Executors：https://forums.swift.org/t/pitch-3-custom-main-and-global-executors/80638
- .NET 宿主中 MainActor 不执行：https://forums.swift.org/t/swift-concurrency-mainactor-does-not-execute-when-swift-dll-is-called-from-net-on-windows/88469
- Swift DLL + WinUI 3 实践：https://github.com/tddworks/ClaudeBar-Windows/issues/2
- swift-winui 状态：https://forums.swift.org/t/the-state-of-winui-and-swift/79963 ，https://github.com/thebrowsercompany/swift-winui（已归档）
- swift-cross-ui Narrator 崩溃：https://github.com/moreSwift/swift-cross-ui/issues/787
- Windows Kit：https://forums.swift.org/t/windows-kit-a-new-swift-projection-for-windows-apis/88363
- GRDB 多平台：https://forums.swift.org/t/grdb-v7-10-0-android-linux-windows-and-sqlcipher-swiftpm/84754
- Windows App SDK 发布：https://github.com/microsoft/WindowsAppSDK/releases
