# PGYMacMenu 软件使用说明

## 1. 安装与启动

构建应用：

```bash
./scripts/build_app.sh
```

构建完成后应用位于：

```text
dist/PGYMacMenu.app
```

双击 `PGYMacMenu.app` 启动后，应用不会出现在 Dock，只会出现在 macOS 菜单栏。
启动时会显示 `PGYMacMenu 已启动` 窗口。默认配置下，关闭最后一个窗口会直接退出应用。

## 2. 初次配置

点击菜单栏中的上传图标，依次配置：

1. `API Key 配置...`
   - 新建配置
   - 填写名称
   - 填写蒲公英 API Key
   - 可选填写安装密码
   - 可选填写该 API Key 默认更新说明
   - 点击保存

2. `更新模板配置...`
   - 新建常用更新说明模板
   - 填写模板名称和模板内容
   - 点击保存

3. `偏好设置...`
   - 可选配置 `aapt` 工具路径
   - 可选配置 Android SDK 目录
   - 可选开启“允许关闭窗口后继续运行”
   - 可选开启“显示菜单栏 PGY 图标”
   - 可选开启“上传成功后自动退出应用”

菜单栏图标默认关闭；只有开启“允许关闭窗口后继续运行”后，才允许开启菜单栏 `PGY` 图标。关闭后台运行时，菜单栏图标会被强制关闭。

`aapt` 工具通常位于：

```text
~/Library/Android/sdk/build-tools/<version>/aapt
```

如果未配置，应用会自动从 Android SDK 默认目录和环境变量中查找。

## 3. 从菜单栏上传 APK

1. 点击菜单栏图标
2. 选择 `上传 APK...`
3. 选择 `.apk` 文件
4. 确认 APK 信息
5. 选择 API Key 配置
6. 输入更新说明，或选择更新模板
7. 点击上传
8. 等待上传与发布完成
9. 查看短链、二维码和蒲公英返回信息

## 4. 从 Finder 右键上传 APK

1. 先启动一次 `PGYMacMenu.app`
2. 在 Finder 中选中 `.apk` 文件
3. 右键打开服务或快速操作菜单，选择 `上传到蒲公英`
4. 后续流程与菜单栏上传一致

如果服务菜单暂未出现，可尝试：

```bash
/System/Library/CoreServices/pbs -flush
```

然后重新启动应用或重新登录 macOS。

## 5. 配置存储说明

- API Key 与安装密码保存到系统 Keychain
- API Key 名称、默认更新说明、更新模板、偏好设置保存到应用 `UserDefaults`
- 应用不会在控制台输出 API Key 或安装密码

## 6. 常见问题

### APK 元信息显示“未识别”

通常是未找到 `aapt`。请在 `偏好设置...` 中配置 `aapt` 可执行文件路径，或配置 Android SDK 目录。

### 上传前提示未配置 API Key

进入 `API Key 配置...` 新建至少一个配置，并填写 API Key。

### Finder 右键入口不可见

先启动一次应用，让 macOS 注册服务；必要时执行：

```bash
/System/Library/CoreServices/pbs -flush
```

然后重新打开 Finder 右键菜单。

### 关闭窗口后应用仍在运行

检查 `偏好设置...` 中是否开启了“允许关闭窗口后继续运行”。默认关闭该选项，关闭最后一个窗口会退出应用。
