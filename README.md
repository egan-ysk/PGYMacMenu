# PGYMacMenu

PGYMacMenu 是一个 macOS 原生工具应用，用于选择 Android APK 并上传到蒲公英。项目基于原 `PGYUpload` Android Studio 插件能力重写，采用 Swift + AppKit 实现，支持菜单栏、Finder 右键服务、API Key 配置、更新模板和 APK 元信息解析。

## 特性

- 上传 APK 到蒲公英：获取上传凭证、上传 APK、轮询发布结果、展示短链和二维码
- 上传前信息确认：展示 APK 名称、包名、版本、SDK、ABI、Debug 状态、文件大小和路径
- 上传成功结果页：展示安装二维码、短链、发布信息、更新说明，并支持复制短链
- Finder 右键入口：选中 `.apk` 文件后可通过服务菜单触发上传
- 菜单栏入口：可上传 APK、打开配置、管理模板和偏好设置
- 多 API Key 配置：支持名称、API Key、安装密码、默认更新说明
- 多更新模板：上传前可快速套用常用发布说明
- APK 元信息解析工具可配置：支持手动指定 `aapt` 或 Android SDK 路径
- 轻量运行：默认关闭最后一个窗口即退出，可按需开启后台运行和菜单栏图标

## 运行要求

- macOS Sequoia 15.0+
- Apple Silicon Mac 或 Intel Mac
- Xcode Command Line Tools，需包含 `swiftc`、`lipo`、`codesign`
- 可选：Android SDK build-tools 中的 `aapt`，用于解析完整 APK 元信息

## 构建

```bash
./scripts/build_app.sh
```

构建完成后产物位于：

```text
dist/PGYMacMenu.app
```

构建脚本会完成：

- 校验 `Info.plist`
- 分别编译 `arm64` 和 `x86_64`
- 使用 `lipo` 生成 universal 可执行文件
- 生成 `.app` Bundle
- 使用 ad-hoc 签名

## 安装

构建后可以直接运行：

```bash
open dist/PGYMacMenu.app
```

也可以复制到系统应用程序目录：

```bash
cp -R dist/PGYMacMenu.app /Applications/
open /Applications/PGYMacMenu.app
```

如果 Finder 右键服务没有立即出现，可以刷新服务菜单：

```bash
/System/Library/CoreServices/pbs -flush
```

然后重新启动应用或重新登录 macOS。

## 使用说明

### 1. 配置 API Key

1. 打开 `PGYMacMenu.app`
2. 进入 `API Key 配置...`
3. 新建配置
4. 填写名称、蒲公英 API Key
5. 可选填写安装密码和默认更新说明
6. 保存

### 2. 配置更新模板

1. 进入 `更新模板配置...`
2. 新建模板
3. 填写模板名称和模板内容
4. 保存

### 3. 配置 APK 解析工具

进入 `偏好设置...`，可手动配置：

- `aapt` 可执行文件路径
- Android SDK 目录

`aapt` 常见路径：

```text
~/Library/Android/sdk/build-tools/<version>/aapt
```

如果未配置，应用会尝试从 `ANDROID_HOME`、`ANDROID_SDK_ROOT` 和常见 SDK 目录自动查找。

### 4. 上传 APK

上传入口有三种：

- 主页面点击 `选择 APK...`
- 菜单栏 `PGY` 图标中选择 `上传 APK...`
- Finder 中右键 `.apk` 文件，选择 `上传到蒲公英`

上传流程：

1. 选择 APK
2. 检查上传前信息
3. 选择 API Key 和更新模板
4. 点击上传
5. 在确认 sheet 中确认目标配置和更新说明
6. 等待上传与发布完成
7. 查看短链和二维码

## 配置与安全

- API Key 和安装密码保存到 macOS Keychain
- API Key 名称、默认更新说明、更新模板、偏好设置保存到应用 `UserDefaults`
- 应用不会在工程目录、日志或构建产物中写入 API Key 和安装密码
- 上传请求使用 `URLSessionConfiguration.ephemeral`，避免 URLSession 磁盘缓存
- APK 上传时使用临时 multipart 文件，不把 APK 整体读入内存

## 项目结构

```text
Sources/PGYMacMenu/
  AppDelegate.swift                    应用生命周期、菜单栏、Finder 服务、文件入口
  Models.swift                         配置模型、APK 信息、蒲公英响应模型
  ConfigurationStore.swift             UserDefaults 与 Keychain 配置读写
  KeychainStore.swift                  Keychain 封装
  ApkMetadataReader.swift              APK 元信息解析
  PgyerClient.swift                    蒲公英上传与发布轮询
  HomeWindowController.swift           主页面
  UploadWindowController.swift         上传前信息、确认 sheet、上传进度
  ResultWindowController.swift         上传成功结果页与二维码
  APIKeySettingsWindowController.swift API Key 配置
  TemplateSettingsWindowController.swift 更新模板配置
  PreferencesWindowController.swift    偏好设置
  UIHelpers.swift                      AppKit UI 工具方法
Resources/
  Info.plist                           Bundle、UTType、Finder Services 配置
scripts/
  build_app.sh                         构建脚本
docs/
  app-design.md                        应用设计文档
  user-guide.md                        软件使用说明
```

## 开发说明

项目不依赖第三方库，直接使用系统框架：

- AppKit
- Foundation
- Security
- UniformTypeIdentifiers
- CoreImage

构建产物会生成到 `build/` 和 `dist/`，这两个目录默认不纳入 Git 版本控制。

## 文档

- [应用设计文档](docs/app-design.md)
- [软件使用说明](docs/user-guide.md)

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
