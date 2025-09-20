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
