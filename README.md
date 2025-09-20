# Album Sync (Flutter)

基于 Flutter 的本地相册 → WebDAV 服务器上传工具。

- 服务器默认：`<自定义 WebDAV 地址>`（可在应用内修改）
- 支持 Android、iOS（MVP 以前台上传为主）
- 相册读取使用 `photo_manager`；WebDAV 访问基于 HTTP（PROPFIND/MKCOL/PUT）

## 功能
- 首次引导：输入服务器地址、用户名、密码与远端根目录；验证后保存
- 首页：相册列表（默认仅图片），下一步进入上传
- 上传页：生成上传计划、并发上传、基础去重（远端存在即跳过）、进度汇总
- 设置：修改凭据、并发、仅 Wi‑Fi、是否包含视频

## Logo 资源
- iOS（无圆角源图）：`assets/logo/album_sync_ios_flat.svg`
- Android 自适应图标：
  - 背景：`assets/logo/adaptive_background.svg`
  - 前景：`assets/logo/adaptive_foreground.svg`
- 预览主标（圆角背景，适合作为宣传图）：`assets/logo/album_sync_logo.svg`
- 单色字形（适合深浅色背景）：`assets/logo/album_sync_glyph.svg`

建议配色：
- 渐变背景：从 `#3B82F6`（蓝）到 `#22D3EE`（青）
- 图形/箭头：纯白（或在单色版使用深灰 `#111827`）

应用图标生成（推荐）：
- 使用 flutter_launcher_icons 按平台生成：
  1) 将上面 SVG 导出为 1024x1024 PNG：
     - iOS：导出为 `assets/logo/ios_icon.png`（基于 `album_sync_ios_flat.svg`，方形无圆角、满铺、无透明）。
     - Android：
       - `assets/logo/adaptive_bg.png`（可用纯色或导出 `adaptive_background.svg`）。
       - `assets/logo/adaptive_fg.png`（由 `adaptive_foreground.svg` 导出，保留四周安全留白）。
  2) 在 `pubspec.yaml` 添加：
     ```yaml
     dev_dependencies:
       flutter_launcher_icons: ^0.13.1
     flutter_icons:
       android: true
       ios: true
       image_path_ios: assets/logo/ios_icon.png
       adaptive_icon_background: assets/logo/adaptive_bg.png # 或 '#3B82F6'
       adaptive_icon_foreground: assets/logo/adaptive_fg.png
     ```
  3) 执行：`flutter pub get && dart run flutter_launcher_icons`
  - 结果：
    - iOS 使用无圆角方形图，系统自动裁圆角（符合 iOS 要求）。
    - Android 生成自适应圆角图标（API 26+），老设备自动生成兼容图标。

## 权限
- Android：INTERNET、ACCESS_NETWORK_STATE、READ_MEDIA_IMAGES、READ_MEDIA_VIDEO（13+）、READ_EXTERNAL_STORAGE（≤12）
- iOS：NSPhotoLibraryUsageDescription

## 运行
```
flutter pub get
flutter run
```

首次运行进入“设置 WebDAV”，验证通过后可在首页点击“开始上传”。

## 注意
- 仅 Wi‑Fi 上传开启时，如当前非 Wi‑Fi，会阻止上传
- 去重策略：上传前以 HEAD/PROPFIND 判断远端是否已存在
- 若服务器证书异常（自签名等），将连接失败并给出提示

## 目录结构（关键部分）
- `lib/main.dart`：入口与路由
- `lib/src/services/settings_service.dart`：设置与安全存储
- `lib/src/services/webdav_service.dart`：WebDAV 连通性校验
- `lib/src/services/media_service.dart`：相册/媒体访问
- `lib/src/core/*`：日志、路径、网络、进度流
- `lib/src/data/db.dart`：Sqflite 任务表
- `lib/src/features/onboarding/*`：首次引导
- `lib/src/features/home/*`：首页与相册列表
- `lib/src/features/settings/*`：设置页
- `lib/src/features/upload/*`：上传控制器与页面

## 未来增强
- 后台计划上传（Android WorkManager / iOS BGTasks）
- 本地哈希去重、冲突自动重命名策略
- 失败列表与单项重试、任务导出/导入
