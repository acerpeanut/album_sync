# Album Sync (Flutter)

基于 Flutter 的本地相册 → WebDAV 服务器上传工具，内置多层去重与跨重装识别能力（内容哈希、远端索引/Manifest、条件请求）。

- 服务器默认：`<自定义 WebDAV 地址>`（可在应用内修改）
- 支持 Android、iOS（MVP 以前台上传为主）
- 相册读取使用 `photo_manager`；WebDAV 访问基于 HTTP（PROPFIND/MKCOL/PUT）

## 功能
- 首次引导：输入服务器地址、用户名、密码与远端根目录；验证后保存
- 首页：相册列表（默认仅图片），下一步进入上传
- 上传页：生成上传计划、并发上传、去重（远端存在/内容哈希）、进度汇总
- 设置：修改凭据、并发、仅 Wi‑Fi、是否包含视频；“去重与重装”高级选项
- 诊断页：重建远端索引、合并/发布 Manifest、仅导入 Manifest、测量/清理临时文件、清理重复队列/修复路径、清理历史并 VACUUM、跳过原因统计

## 权限
- Android：INTERNET、ACCESS_NETWORK_STATE、READ_MEDIA_IMAGES、READ_MEDIA_VIDEO（13+）、READ_EXTERNAL_STORAGE（≤12）
- iOS：NSPhotoLibraryUsageDescription

## 运行
```
flutter pub get
flutter analyze
flutter test -r expanded
flutter run -d macos   # 或 -d chrome / 连接的设备
```

首次运行进入“设置 WebDAV”，验证通过后可在首页点击“开始上传”。

## 注意
- 仅 Wi‑Fi 上传开启时，如当前非 Wi‑Fi，会阻止上传
- 去重策略（多层）：
  - 扫描期（可选）：计算 MD5，命中远端索引（hash → path）则不入队
  - 上传期：
    - HEAD/PROPFIND 尺寸一致 → 直接跳过
    - PUT 携带 `If-None-Match: *` 防并发；返回 412/409 视为已存在 → 跳过
    - 若启用内容哈希：PUT 携带 `OC-Checksum: MD5:<hex>`（Nextcloud/ownCloud 支持）；上传成功/412 后写回索引
    - 可选 MOVE：命中哈希但路径不同，且开启“允许重组（MOVE）”时尝试服务器 MOVE 而非重传
- 跨重装：
  - 首次/间隔>24h 将后台引导远端索引（递归 PROPFIND，或优先导入 Manifest）；诊断页可手动触发
  - Manifest 快速引导：支持从 `<baseDir>/.album_sync/index-v1.json.gz` 或 `.album_sync/index/*.jsonl` 导入；上传成功会追加分片；诊断页可“一键合并并发布” gz
- 临时空间：上传完成/失败会清理任务使用的临时副本；首页延时、队列结束后均会做后台清理；诊断页可“一键清理临时文件”
- 若服务器证书异常（自签名等），将连接失败并给出提示

## 目录结构（关键部分）
- `lib/main.dart`：入口与路由
- `lib/src/services/settings_service.dart`：设置与安全存储
- `lib/src/services/webdav_service.dart`：WebDAV 连通性校验
- `lib/src/services/media_service.dart`：相册/媒体访问
- `lib/src/core/*`：日志、路径、网络、进度流
- `lib/src/data/db.dart`：Sqflite 任务与索引表（v4：upload_tasks.hash、asset_index、remote_index）
- `lib/src/features/onboarding/*`：首次引导
- `lib/src/features/home/*`：首页与相册列表
- `lib/src/features/settings/*`：设置页
- `lib/src/features/upload/*`：上传控制器与页面
- `lib/src/services/remote_indexer.dart`：远端索引引导/Manifest 读写、并发扫描、进度/取消
- `lib/src/services/hash_service.dart`：流式 MD5
- `lib/src/services/temp_cleaner.dart`：临时文件清理与占用测量
- `lib/src/services/metrics_service.dart`：会话内跳过原因统计

## 设置（去重与重装）
- 启用内容哈希去重：默认开；上传期携带 OC-Checksum（兼容 Nextcloud/ownCloud）
- 仅 Wi‑Fi 计算哈希：默认开，避免移动网络算大文件 MD5
- 启动时引导远端索引：默认开；remote_index 为空或>24h 时后台引导
- 扫描阶段哈希去重（实验）：扫描期命中远端索引即不入队，适合二次/重装场景
- 允许按新规则重组（MOVE）：命中哈希但路径不同，尝试 MOVE 而非重传
- 索引并发/超时：控制远端索引扫描器的并发度与请求超时

## 诊断页（Diagnostics）
- 重建远端哈希索引：递归 PROPFIND（优先导入 Manifest），显示进度，可取消
- 合并并发布 Manifest：将 `.album_sync/index/*.jsonl` 合并为 `index-v1.json.gz` 并清理分片
- 仅导入 Manifest：不递归扫描，直接从 gz/分片导入索引
- 测量临时占用 / 清理临时文件：查看与释放 app 临时目录空间
- 清理重复队列 / 修复队列路径编码 / 清理历史任务并 VACUUM
- 跳过原因统计（会话内）：HASH_HIT / HTTP_412 / SIZE_MATCH / MOVE_COLLISION / SCAN_EARLY_BREAK

## 服务器兼容性
- Nextcloud/ownCloud（Sabre/DAV）：支持 `OC-Checksum`；推荐优先启用内容哈希。
- 通用 WebDAV：多数支持 ETag 与 `If-None-Match`；缺少 checksum 时回退为 ETag+size/文件名判定。

## 未来增强
- 后台计划上传（Android WorkManager / iOS BGTasks）
- Manifest 合并/压缩与校验的进一步优化（断点续作、失败恢复、重复校验）
- 失败列表与单项重试、任务导出/导入
