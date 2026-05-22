# PGYMacMenu 应用设计文档

## 1. 项目目标

PGYMacMenu 将原 Android Studio 插件 `PGYUpload` 的蒲公英 APK 发布能力迁移为 macOS 原生菜单栏应用。应用定位为轻量工具：平时仅保留菜单栏入口，用户选择 APK 后再创建上传任务，任务结束后释放窗口与网络对象。

## 2. 功能范围

- 选择 APK 并上传到蒲公英
- 上传前展示 APK 元信息
- 管理多个 API Key 配置
- 管理多个更新说明模板
- 配置 APK 元信息解析工具
- 支持菜单栏入口
- 支持 Finder 右键服务入口，仅面向 `.apk` 文件
- 上传后展示蒲公英短链、二维码、版本信息和更新说明

## 3. macOS 设计规范

应用采用 `LSUIElement` 工具形态，不占用 Dock。双击应用时会显示一个原生启动窗口。默认不常驻、不显示菜单栏图标，关闭最后一个界面后应用完全退出；用户可在偏好设置中开启“允许关闭窗口后继续运行”，并在此前提下单独开启菜单栏 `PGY` 图标。

窗口使用原生 AppKit 控件：

- `NSStatusItem`：菜单栏入口
- `NSMenu`：上传、配置、退出等命令
- `NSWindowController`：配置、上传、结果窗口生命周期管理
- `NSOpenPanel`：选择 APK、选择 `aapt`、选择 Android SDK
- `NSAlert`：确认上传与错误提示
- `NSTableView`：API Key 与模板列表
- `NSProgressIndicator`：上传进度与发布轮询状态

界面文案遵循 macOS 工具应用风格，避免营销式页面；配置、上传、结果三个主要窗口均以表单和信息分组为主。

## 4. 架构设计

源码位于 `Sources/PGYMacMenu`：

- `AppDelegate.swift`：应用生命周期、菜单栏、Finder Services、文件打开入口
- `Models.swift`：配置模型、APK 信息、蒲公英响应模型、通用错误
- `ConfigurationStore.swift`：配置读写，非敏感数据存 `UserDefaults`
- `KeychainStore.swift`：API Key 与安装密码存入系统 Keychain
- `ApkMetadataReader.swift`：调用 `aapt dump badging` 解析 APK 元信息
- `PgyerClient.swift`：蒲公英 Token 获取、COS 上传、发布结果轮询
- `APIKeySettingsWindowController.swift`：API Key 配置窗口
- `TemplateSettingsWindowController.swift`：更新模板配置窗口
- `PreferencesWindowController.swift`：偏好设置窗口
- `UploadWindowController.swift`：上传确认、进度和取消
- `ResultWindowController.swift`：上传结果与二维码展示
- `UIHelpers.swift`：AppKit 表单和提示工具方法

## 5. 上传流程

1. 用户从菜单栏、Finder 服务或打开文件触发 `.apk`
2. `ApkMetadataReader` 读取文件大小、修改时间，并调用 `aapt` 解析包名、版本、SDK、ABI、Debug 状态
3. 上传窗口展示 APK 信息
4. 用户选择 API Key、选择或编辑更新说明
5. 用户确认上传
6. `PgyerClient` 请求 `getCOSToken`
7. 将 APK 以临时 multipart 文件上传到 COS
8. 轮询 `buildInfo`
9. 上传完成后展示短链、二维码和发布信息

## 6. APK 元信息解析工具配置

解析策略：

1. 优先使用偏好设置中的 `aapt` 可执行文件路径
2. 如果配置的是目录，则检查目录下的 `aapt` 或 `build-tools/*/aapt`
3. 再使用偏好设置中的 Android SDK 目录
4. 再检查 `ANDROID_HOME`、`ANDROID_SDK_ROOT`
5. 最后检查常见默认目录：
   - `~/Library/Android/sdk`
   - `~/Android/Sdk`

找不到 `aapt` 时不阻塞上传，只将 APK 元信息显示为“未识别”。

## 7. Finder 右键入口

`Resources/Info.plist` 声明了：

- `CFBundleDocumentTypes`：注册 `.apk` 文件类型
- `UTExportedTypeDeclarations`：声明 `com.android.package-archive`
- `UTImportedTypeDeclarations`：兼容系统或第三方常见的 `public.archive.apk`
- `NSServices`：提供“上传到蒲公英”服务，限定 Finder 上下文和 APK 文件类型

应用启动时设置 `NSApp.servicesProvider`，并实现 `uploadAPKService:userData:error:` 作为 Finder 服务入口。

## 8. 内存与性能策略

- 应用默认不常驻，关闭最后一个窗口后退出；只有开启“允许关闭窗口后继续运行”时才保留后台进程
- 菜单栏图标默认关闭，且在未允许后台运行时强制关闭
- 常驻模式下对象仅包含配置仓库、可选菜单和少量窗口控制器引用
- API Key 与安装密码使用 Keychain，不在日志中输出
- 上传任务每次创建独立 `PgyerClient`
- `URLSessionConfiguration.ephemeral` 避免磁盘缓存
- APK multipart 请求体写入临时文件，避免将大 APK 整体读入内存
- 上传窗口和结果窗口关闭后从 `AppDelegate` 的活动列表移除
- 上传完成后删除临时 multipart 文件

## 9. 系统兼容性

- 最低目标：macOS Sequoia 15.0
- 当前构建脚本目标：`arm64-apple-macosx15.0` 与 `x86_64-apple-macosx15.0`，产物为 universal app
- 使用原生 Swift + AppKit + Foundation + Security，不依赖第三方库

## 10. 构建产物

构建命令：

```bash
./scripts/build_app.sh
```

产物：

```text
dist/PGYMacMenu.app
```

构建脚本会执行：

- `plutil -lint`
- `swiftc` 编译
- 生成 `.app` Bundle
- ad-hoc codesign
