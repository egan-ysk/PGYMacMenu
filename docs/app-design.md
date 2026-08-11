# PGYMacMenu 应用设计文档

## 1. 项目目标

PGYMacMenu 是面向蒲公英 APK 发布流程的 macOS 原生轻量工具。应用默认通过启动窗口进入；用户可按需开启后台运行和菜单栏入口。选择 APK 后才创建上传任务，任务结束后释放窗口与网络对象。

## 2. 功能范围

- 选择 APK 并上传到蒲公英
- 上传前展示 APK 元信息
- 管理多个 API Key 配置
- 管理多个更新说明模板
- 通过 WebDAV 端到端加密同步可迁移配置
- 配置 APK 元信息解析工具
- 支持菜单栏入口
- 支持 Finder 右键服务入口，仅面向 `.apk` 文件
- 上传后展示蒲公英短链、二维码、版本信息和更新说明
- 提供完整的多尺寸 macOS 应用图标

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
- `NSTabView`：组织“通用 / 同步”偏好设置

界面文案遵循 macOS 工具应用风格，避免营销式页面；配置、上传、结果三个主要窗口均以表单和信息分组为主。

## 4. 架构设计

源码位于 `Sources/PGYMacMenu`：

- `AppDelegate.swift`：应用生命周期、菜单栏、Finder Services、文件打开入口
- `Models.swift`：配置模型、APK 信息、蒲公英响应模型、通用错误
- `ConfigurationStore.swift`：版本化配置 manifest、旧数据迁移、原子保存与变更事件
- `KeychainStore.swift`：分代 Keychain 密钥包、同步 bootstrap 和设备锚点
- `SyncModels.swift`：HLC revision、版本化记录、删除墓碑与确定性合并
- `SyncCrypto.swift`：PBKDF2-HMAC-SHA256、AES-GCM 信封和内容哈希
- `ImmutableSyncSnapshot.swift`：不可变加密快照、carrier 引用与内容寻址布局
- `WebDAVClient.swift`：HTTPS WebDAV、条件写入、独占锁、目录枚举和临时探针
- `SyncCoordinator.swift`：三路径串行手动同步、待上传状态、合并与回放检测
- `ApkMetadataReader.swift`：调用 `aapt dump badging` 解析 APK 元信息
- `PgyerClient.swift`：蒲公英 Token 获取、COS 上传、发布结果轮询
- `APIKeySettingsWindowController.swift`：API Key 配置窗口
- `TemplateSettingsWindowController.swift`：更新模板配置窗口
- `PreferencesWindowController.swift`：偏好设置窗口
- `UploadWindowController.swift`：上传确认、进度和取消
- `ResultWindowController.swift`：上传结果与二维码展示
- `UIHelpers.swift`：AppKit 表单和提示工具方法

## 5. 配置存储与同步设计

### 5.1 数据边界

| 数据 | 本机存储 | WebDAV 同步 |
| --- | --- | --- |
| API 配置名称、默认更新说明 | 版本化 manifest | 加密同步 |
| API Key、安装密码 | Keychain | 加密同步 |
| 更新说明模板 | 版本化 manifest | 加密同步 |
| 后台运行、菜单栏、成功后退出 | 版本化 manifest | 加密同步 |
| `aapt`、Android SDK 路径 | 版本化 manifest | 不同步 |
| WebDAV 用户名、密码、同步口令 | Keychain | 不上传 |
| 设备 ID、数据集和 generation/hash 锚点 | Keychain | 不上传 |

旧版分散在 `UserDefaults` 和 Keychain 中的数据会幂等迁移到版本化 manifest 和分代 Keychain 密钥包。保存时先完整写入新一代秘密，再原子切换 manifest；中途失败不会暴露半份配置。配置仓库发布带变更来源和数据类别的事件，远端导入标记为 remote，避免再次触发回声上传。

### 5.2 同步数据模型与合并

`SyncDocument v1` 包含 `datasetID`、单调递增的 `generation`、前驱文档哈希，以及 API 配置、模板和行为偏好三类记录。

- 每条记录包含稳定 UUID、不可变顺序值、HLC revision、写入设备 ID 和删除墓碑
- 不同 UUID 的修改直接合并；同一 UUID 按 HLC revision 决定新旧，完全相同 revision 时以设备 ID 确定性裁决
- 删除记录永久保留墓碑，避免长期离线设备重新引入已删除项目
- 三项行为偏好作为一个整体记录合并，并始终满足关闭后台运行时菜单栏图标也关闭
- 应用远端偏好时只更新可迁移布尔字段，保留当前 Mac 的 `aapt` 和 Android SDK 路径

### 5.3 加密信封

`EncryptedEnvelope v1` 的明文头部只包含格式版本、KDF 参数、16-byte 随机 salt、nonce、ciphertext 和认证 tag。独立同步口令至少 12 个字符且不裁剪首尾空格；使用 PBKDF2-HMAC-SHA256 600,000 次派生 AES-256 密钥，再由 AES-GCM 使用每次新生成的随机 nonce 加密并认证完整 `SyncDocument`。

解密层对信封版本、KDF 参数和输入大小设置上限。错误口令、密文或头部篡改、未知版本均作为不可恢复的本次同步错误处理，不会触发远端覆盖。应用自身不会主动把 API Key、安装密码与连接凭据写入日志；同步模块不会把这些值写入临时文件。

### 5.4 WebDAV 并发协议

- 客户端只接受系统信任证书的 HTTPS 根 URL，拒绝 HTTP、跨域或 HTTPS 降级重定向
- 使用无缓存、无 Cookie、无共享凭据存储的 ephemeral `URLSession`
- 强 ETag 路径：单文件首次创建使用 `If-None-Match: *`，更新使用最近 GET 返回的强 ETag 和 `If-Match`；遇到 `412 Precondition Failed` 时重新拉取、解密、合并并最多重试三轮
- exclusive `LOCK` 路径：弱 ETag 或缺少 ETag 时，只有严格验证标准 WebDAV exclusive `LOCK`/`UNLOCK` 后，才用锁令牌保护 GET、合并、PUT 和写后验证
- 不可变快照路径：前两种机制不可用时，在原远端文件同级的 `<文件名>.d/` 目录保存 `genesis.pgy` 和以密文 SHA-256 命名的 `.pgy` 对象；对象优先用通过安全验证的 `If-None-Match: *` 创建。若条件创建不安全，则先写入随机临时对象，再以通过验证的同目录 WebDAV `MOVE` 和 `Overwrite: F` 发布；目标已存在必须拒绝移动且两端内容不变，不允许无条件覆盖已有对象
- 不可变快照包含完整加密状态和已验证的父 carrier 引用；客户端校验数据集、哈希、父链和本机锚点，合并所有有效分支后追加后继对象，从而保留多设备并发修改并检测已观察历史的回放
- 不可变仓库最多接受 512 个对象、单次最多下载 64 MiB；超限、缺失 carrier、图结构异常或锚点回退均停止同步
- 三种安全机制均不可用时停止上传，不退化为无条件 PUT
- 嵌套远端路径缺少父目录时逐级 `MKCOL`
- 上传后必须重新 GET、解密并核对 generation 和内容哈希，确认成功后才清除 dirty 状态
- 已见过远端数据集后突然收到 `404`、检测到 generation 回退或前驱哈希异常时停止写入

连接测试不读取或修改单文件配置、`genesis.pgy` 或任何真实快照。嵌套相对路径缺少父目录时会先按配置执行 `MKCOL`；随后只使用独立临时探针执行 PUT、GET、冲突写入、`MOVE` 和 DELETE。探针要求重复 `If-None-Match: *` 创建返回 `412` 且正文不变；强 ETag 路径还要求错误 `If-Match` 返回 `412`、正确 `If-Match` 更新成功。否则严格探测 exclusive `LOCK`；不可变创建则在随机临时目录中验证同目录 `MOVE` 携带 `Overwrite: F`：先暂存随机对象，首次移动后确认内容与源文件删除，再以另一随机对象冲突移动并确认目标和来源均未被改写。所有安全机制均未通过时才报告不支持安全并发同步。只有“立即同步”会拉取或上传真实配置。

### 5.5 协调器与生命周期

`SyncCoordinator` actor 保证 single-flight，同一时刻只有一次手动同步或 WebDAV 写入。配置保存和删除只设置 dirty 与“待手动同步”状态；同步过程中再次发生的本地变更会继续保留 dirty 标记，由当前手动同步重试或留待用户下次手动同步。

只有用户点击“立即同步”才会读取或写入远端配置。保存 WebDAV 设置、应用启动、重新激活和本地变更通知只更新或读取本机状态，不创建网络请求；退出时不执行同步或 flush，也不延迟等待上传。失败或尚未上传的修改继续保留 dirty 状态，直到后续手动同步成功。

偏好设置使用原生“通用 / 同步”标签页。同步页包含连接字段、口令确认、测试连接、保存设置、立即同步、移除配置和状态；保存设置只持久化本机连接信息，不隐式执行连接测试或同步。移除配置只删除本机连接信息，不删除远端备份和本机回放锚点。

## 6. 上传流程

1. 用户从菜单栏、Finder 服务或打开文件触发 `.apk`
2. `ApkMetadataReader` 读取文件大小、修改时间，并调用 `aapt` 解析包名、版本、SDK、ABI、Debug 状态
3. 上传窗口展示 APK 信息
4. 用户选择 API Key、选择或编辑更新说明
5. 用户确认上传
6. `PgyerClient` 请求 `getCOSToken`
7. 将 APK 以临时 multipart 文件上传到 COS
8. 轮询 `buildInfo`
9. 上传完成后展示短链、二维码和发布信息

## 7. APK 元信息解析工具配置

解析策略：

1. 优先使用偏好设置中的 `aapt` 可执行文件路径
2. 如果配置的是目录，则检查目录下的 `aapt` 或 `build-tools/*/aapt`
3. 再使用偏好设置中的 Android SDK 目录
4. 再检查 `ANDROID_HOME`、`ANDROID_SDK_ROOT`
5. 最后检查常见默认目录：
   - `~/Library/Android/sdk`
   - `~/Android/Sdk`

找不到 `aapt` 时不阻塞上传，只将 APK 元信息显示为“未识别”。

## 8. Finder 右键入口

`Resources/Info.plist` 声明了：

- `CFBundleDocumentTypes`：注册 `.apk` 文件类型
- `UTExportedTypeDeclarations`：声明 `com.android.package-archive`
- `UTImportedTypeDeclarations`：兼容系统或第三方常见的 `public.archive.apk`
- `NSServices`：提供“上传到蒲公英”服务，限定 Finder 上下文和 APK 文件类型

应用启动时设置 `NSApp.servicesProvider`，并实现 `uploadAPKService:userData:error:` 作为 Finder 服务入口。

## 9. 内存与性能策略

- 应用默认不常驻，关闭最后一个窗口后退出；只有开启“允许关闭窗口后继续运行”时才保留后台进程
- 菜单栏图标默认关闭，且在未允许后台运行时强制关闭
- 常驻模式下对象仅包含配置仓库、可选菜单和少量窗口控制器引用
- API Key、安装密码、WebDAV 凭据与同步口令使用 Keychain，应用自身不主动在日志中输出
- 加密和 WebDAV 请求只在同步期间创建，并由 actor 串行管理
- 上传任务每次创建独立 `PgyerClient`
- `URLSessionConfiguration.ephemeral` 避免磁盘缓存
- APK multipart 请求体写入专属 `0700` 临时目录中的 `0600` 文件，避免将大 APK 整体读入内存
- 上传窗口和结果窗口关闭后从 `AppDelegate` 的活动列表移除
- 上传完成、失败或对象释放时删除临时 multipart 文件；后续上传会清理进程已退出且超过一小时的残留

## 10. 系统兼容性

- 最低目标：macOS Sequoia 15.0
- 当前构建脚本目标：`arm64-apple-macosx15.0` 与 `x86_64-apple-macosx15.0`，产物为 universal app
- 使用原生 Swift + AppKit + CommonCrypto + CryptoKit + Foundation + Security，不依赖第三方库

## 11. 构建、图标与测试

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
- 从 `Resources/AppIconSource.png` 生成十种标准 iconset PNG 和 `AppIcon.icns`
- `swiftc` 分别编译 arm64 与 x86_64，再用 `lipo` 合成 universal 可执行文件
- 生成 `.app` Bundle
- 将 `AppIcon.icns` 复制到 Bundle，并由 `CFBundleIconFile` 关联
- ad-hoc codesign

图标母版为 1024×1024 sRGB PNG：深石墨底板、青绿色应用包裹、白色上传箭头与少量暖色点缀，不含文字、平台商标或细小装饰。主体位于中心安全区，圆角外缘透明，保证小尺寸仍有清晰轮廓。构建脚本会先校验尺寸；所有图标生成和复制均发生在 codesign 之前。

母版由 `scripts/generate_app_icon.swift` 使用 Core Graphics 确定性绘制，可通过 `swift scripts/generate_app_icon.swift Resources/AppIconSource.png` 重新生成。

Swift Package 仅作为可重复执行的测试入口，正式 `.app` 仍由脚本构建：

```bash
swift test
```

测试覆盖 HLC 与逐记录合并、墓碑和顺序、偏好约束、PBKDF2/AES-GCM 往返与篡改、WebDAV 条件写入、ETag、独占锁和不可变快照安全探测、手动同步网络边界、旧数据迁移与恢复边界。发布前还需检查 universal 架构、plist、十种 iconset 尺寸和严格 codesign。

## 12. 恢复与安全边界

- 同一台 Mac 保留 Keychain 时，卸载重装可恢复 WebDAV bootstrap；用户点击“立即同步”后拉取远端配置
- 换机或清空 Keychain 后，用户必须重新输入 WebDAV 信息和原同步口令
- 忘记同步口令后无法解密远端备份，v1 不提供找回或静默重置
- 单文件锚点可检测 dataset 替换、同代篡改、generation 降低和相邻代前驱异常；单文件不保留中间版本，因此无法证明跨多代跳跃一定沿当前锚点演进
- 不可变仓库锚点会固定 genesis、已接受 carrier 和已观察对象清单，可在本机检测这些远端对象被替换或隐藏；全新设备仍无法证明服务器是否回放旧的合法密文
- 首次迁移到不可变仓库前必须升级所有设备；迁移后旧构建继续写入单文件的变更不会被不可变仓库导入
- 本版本不使用 iCloud、CloudKit、App Sandbox entitlement、Developer ID 或 Mac App Store 分发迁移
