import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import '../../core/logger.dart';
import '../../core/path_utils.dart';
import '../../core/config.dart';
import '../../core/network.dart';
import '../../core/progress_stream.dart';
import '../../data/db.dart';
import '../../services/settings_service.dart';

class UploadSummary {
  final int total;
  final int queued;
  final int running;
  final int done;
  final int failed;
  final bool paused;

  const UploadSummary(
      {required this.total,
      required this.queued,
      required this.running,
      required this.done,
      required this.failed,
      this.paused = false});
}

class UploadController extends StateNotifier<AsyncValue<UploadSummary>> {
  UploadController(this.ref) : super(const AsyncValue.data(UploadSummary(total: 0, queued: 0, running: 0, done: 0, failed: 0, paused: false)));

  final Ref ref;
  bool _cancelling = false;
  bool _paused = false;
  final _client = http.Client();
  final Set<int> _cancelled = {};

  Future<void> buildPlanAndStart() async {
    _cancelling = false;
    state = const AsyncValue.loading();
    try {
      final settings = ref.read(settingsControllerProvider).value!;
      // 确保相册权限
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.isAuth) {
        throw Exception('未获得照片权限，请在系统设置中授予相册访问权限');
      }
      log.i('buildPlan: start wifiOnly=${settings.wifiOnly} includeVideos=${settings.includeVideos} baseDir=${settings.baseRemoteDir}');
      await AppDatabase.resetRunningToQueued();
      await AppDatabase.cleanupQueuedDuplicates();
      if (settings.wifiOnly) {
        final wifi = await isOnWifi();
        if (!wifi) {
          throw Exception('当前非 Wi‑Fi 网络，已按设置阻止上传');
        }
      }
      // Enumerate albums and assets
      final includeVideos = settings.includeVideos;
      FilterOptionGroup? filterGroup;
      if (settings.incrementalOnly) {
        final lastTs = await ref.read(settingsServiceProvider).loadLastSuccessTs();
        final now = DateTime.now();
        final minDt = lastTs != null
            ? DateTime.fromMillisecondsSinceEpoch(lastTs - 3600 * 1000) // 回溯1小时容错
            : now.subtract(Duration(days: settings.recentDays));
        filterGroup = FilterOptionGroup(
          createTimeCond: DateTimeCond(min: minDt, max: now),
          orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
        );
      }
      final paths = await PhotoManager.getAssetPathList(
        type: includeVideos ? RequestType.common : RequestType.image,
        onlyAll: false,
        filterOption: filterGroup,
      );
      log.i('buildPlan: albums=${paths.length}');

      // Clear previous queued tasks to avoid duplication
      // Keep done/failed for history; we could clear table but here we just append.

      const pageSize = 500;
      final List<UploadTask> tasks = [];
      final existing = await AppDatabase.existingAssetIds(
          includeQueued: true, includeRunning: true, includeDone: true);
      final seen = <String>{...existing};
      int skipped = 0;
      int consecutiveSeen = 0;
      const seenBreakThreshold = 500;
      bool workersStarted = false;
      final workerFutures = <Future<void>>[];
      void startWorkersIfNeeded() {
        if (!workersStarted && settings.parallelScanUpload) {
          workersStarted = true;
          final parallel = settings.maxParallelUploads;
          for (int i = 0; i < parallel; i++) {
            workerFutures.add(_worker());
          }
        }
      }

      for (final p in paths) {
        final albumTitle = sanitizeSegment(p.name);
        int page = 0;
        while (true) {
          final assets = await p.getAssetListPaged(page: page, size: pageSize);
          if (assets.isEmpty) break;
          if (kVerboseLog) log.i('scan: album=$albumTitle page=$page size=${assets.length}');
          for (final a in assets) {
            if (_cancelling) return;
            if (seen.contains(a.id)) { skipped++; consecutiveSeen++; continue; }
            seen.add(a.id);
            consecutiveSeen = 0;
            final filename = _computeFileNameFast(a);
            final remotePath = _buildRemotePath(
              baseDir: settings.baseRemoteDir ?? '/Albums',
              albumTitle: albumTitle,
              fileName: filename,
            );
            tasks.add(UploadTask(
              assetId: a.id,
              albumTitle: albumTitle,
              remotePath: remotePath,
              bytesTotal: 0,
              status: TaskStatus.queued,
            ));
          }
          // 流式入库 + 启动上传
          if (tasks.isNotEmpty) {
            await AppDatabase.insertTasks(tasks);
            await _refreshStats();
            startWorkersIfNeeded();
            tasks.clear();
          }
          if (consecutiveSeen >= seenBreakThreshold) {
            if (kVerboseLog) log.i('scan: break early album=$albumTitle due to seen streak=$consecutiveSeen');
            break;
          }
          page++;
        }
      }

      if (tasks.isNotEmpty) {
        await AppDatabase.insertTasks(tasks);
        await _refreshStats();
        startWorkersIfNeeded();
        tasks.clear();
      }
      log.i('buildPlan: enqueued=${tasks.length} skipped=$skipped existingCached=${existing.length}');

      if (workersStarted) {
        await Future.wait(workerFutures);
      } else {
        // 没启动过（可能没有任务），按需启动一次以便消费零星任务
        final parallel = settings.maxParallelUploads;
        final futures = List.generate(parallel, (_) => _worker());
        await Future.wait(futures);
      }
      await _refreshStats();
    } catch (e, st) {
      log.e('buildPlanAndStart error: $e\n$st');
      state = AsyncValue.error(e, st);
    }
  }

  // Start workers without rescanning; only consumes existing queue.
  Future<void> startQueuedUploads() async {
    if (_paused) {
      // do nothing while paused
      await _refreshStats();
      return;
    }
    _cancelling = false;
    state = const AsyncValue.loading();
    try {
      final settings = ref.read(settingsControllerProvider).value!;
      if (settings.wifiOnly) {
        final wifi = await isOnWifi();
        if (!wifi) {
          throw Exception('当前非 Wi‑Fi 网络，已按设置阻止上传');
        }
      }
      final parallel = settings.maxParallelUploads;
      final futures = List.generate(parallel, (_) => _worker());
      await Future.wait(futures);
      await _refreshStats();
    } catch (e, st) {
      log.e('startQueuedUploads error: $e\n$st');
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> requeueOne(int id) async {
    await AppDatabase.requeueTask(id);
    await _refreshStats();
  }

  Future<void> deleteOne(int id) async {
    await AppDatabase.deleteTask(id);
    await _refreshStats();
  }

  Future<void> cancelOne(int id) async {
    _cancelled.add(id);
    await AppDatabase.updateStatus(id, TaskStatus.failed, lastError: '用户取消');
    await _refreshStats();
  }

  Future<void> cancel() async {
    _cancelling = true;
  }

  void pause() {
    _paused = true;
    _refreshStats();
  }

  void resume() {
    _paused = false;
    _refreshStats();
  }

  void togglePause() => _paused ? resume() : pause();

  String _buildRemotePath({required String baseDir, required String albumTitle, required String fileName}) {
    // Split baseDir to avoid encoding internal slashes as %2F
    final base = baseDir.startsWith('/') ? baseDir.substring(1) : baseDir;
    final baseSegs = base
        .split('/')
        .where((e) => e.isNotEmpty)
        .toList();
    final segs = [
      ...baseSegs,
      albumTitle,
      fileName,
    ].where((e) => e.isNotEmpty).toList();
    return joinUrlSegments(segs);
  }

  Future<String> _computeFileName(AssetEntity a, File file) async {
    final original = a.title;
    if (original != null && original.isNotEmpty) {
      return sanitizeSegment(original);
    }
    final parts = file.path.split('.');
    final ext = parts.length > 1 ? parts.last : 'jpg';
    final ts = a.createDateTime.millisecondsSinceEpoch;
    return sanitizeSegment('${ts}_${a.id}.$ext');
  }

  String _computeFileNameFast(AssetEntity a) {
    final original = a.title;
    if (original != null && original.isNotEmpty) {
      return sanitizeSegment(original);
    }
    String ext = 'jpg';
    final mt = a.mimeType;
    if (mt != null && mt.isNotEmpty) {
      if (mt.contains('png')) ext = 'png';
      else if (mt.contains('heic') || mt.contains('heif')) ext = 'heic';
      else if (mt.contains('jpeg') || mt.contains('jpg')) ext = 'jpg';
      else if (mt.contains('gif')) ext = 'gif';
    }
    final ts = a.createDateTime.millisecondsSinceEpoch;
    return sanitizeSegment('${ts}_${a.id}.$ext');
  }

  Future<void> _worker() async {
    final settings = ref.read(settingsControllerProvider).value!;
    final baseUrl = settings.baseUrl!;
    final username = settings.username!;
    final password = await ref.read(settingsServiceProvider).loadPassword() ?? '';

    while (!_cancelling) {
      // Pause gate: stop claiming new tasks while paused
      while (_paused && !_cancelling) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final task = await AppDatabase.claimNextQueued();
      if (task == null) break;
      if (kVerboseLog) log.i('worker: claim id=${task.id} asset=${task.assetId} path=${task.remotePath}');
      // 立即刷新一次统计，体现“进行中+1/队列-1”
      await _refreshStats();
      try {
        if (_cancelled.contains(task.id)) {
          await AppDatabase.updateStatus(task.id!, TaskStatus.failed, lastError: '用户取消');
          _cancelled.remove(task.id);
          continue;
        }
        await _ensureRemoteDir(baseUrl, username, password, task.remotePath);

        // Skip if exists
        final exist = await _remoteExists(baseUrl, username, password, task.remotePath);
        if (exist) {
          if (kVerboseLog) log.i('worker: exists, skip id=${task.id}');
          await AppDatabase.updateProgress(task.id!, task.bytesTotal, TaskStatus.done);
          continue;
        }

        if (kVerboseLog) log.i('worker: resolving local file for asset=${task.assetId}');
        final file = await _assetFile(task.assetId);
        if (file == null) {
          if (kVerboseLog) log.w('worker: local file not found asset=${task.assetId}');
          await _handleFailure(task, '无法访问文件');
          continue;
        }
        final size = await file.length();
        if (kVerboseLog) log.i('worker: will PUT size=$size id=${task.id}');
        // Persist total size for progress UI (only once per task)
        try { await AppDatabase.updateTotalBytes(task.id!, size); } catch (_) {}
        int sent = 0;
        int lastRefresh = DateTime.now().millisecondsSinceEpoch;
        final stream = ProgressByteStream(file.openRead(), (n) async {
          sent += n;
          await AppDatabase.updateProgress(task.id!, sent, TaskStatus.running);
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastRefresh > 800) {
            lastRefresh = now;
            await _refreshStats();
          }
        });

        final uri = Uri.parse(_normalizeBaseUrl(baseUrl) + task.remotePath.substring(1));
        final req = http.StreamedRequest('PUT', uri);
        req.contentLength = size;
        req.headers['Authorization'] = _basicAuth(username, password);
        req.headers['Content-Type'] = 'application/octet-stream';
        if (kDryRun) {
          if (kVerboseLog) log.w('worker: DRY_RUN skip PUT id=${task.id}');
          await AppDatabase.updateProgress(task.id!, 0, TaskStatus.done);
        } else {
          try {
            // Strategy: small files buffered, larger files streaming with progress.
            // Lower threshold to 4MB to avoid long blocking waits without progress.
            if (size <= 4 * 1024 * 1024) {
              final bytes = await file.readAsBytes();
              final r = await _client
                  .put(
                    uri,
                    headers: {
                      'Authorization': _basicAuth(username, password),
                      'Content-Type': 'application/octet-stream',
                    },
                    body: bytes,
                  )
                  .timeout(const Duration(seconds: 60));
              if (kVerboseLog) log.i('worker: PUT(buffered) status=${r.statusCode} id=${task.id}');
              if (r.statusCode >= 200 && r.statusCode < 300) {
                await AppDatabase.updateProgress(task.id!, size, TaskStatus.done);
                await ref.read(settingsServiceProvider).markLastSuccessNow();
              } else {
                await _handleFailure(task, 'HTTP ${r.statusCode}');
              }
            } else {
              // Add explicit connection close to avoid problematic keep-alive stalls on some servers
              req.headers['Connection'] = 'close';
              // Begin sending before piping body to ensure the consumer is attached to the sink
              final mb = (size / (1024 * 1024)).ceil();
              final secs = (60 + mb * 2).clamp(60, 600);
              final responseFuture = _client.send(req).timeout(Duration(seconds: secs));
              await req.sink.addStream(stream); // now producer feeds an active consumer
              await req.sink.close();
              final resp = await responseFuture;
              if (kVerboseLog) log.i('worker: PUT(stream) status=${resp.statusCode} id=${task.id}');
              if (resp.statusCode >= 200 && resp.statusCode < 300) {
                await AppDatabase.updateProgress(task.id!, size, TaskStatus.done);
                await ref.read(settingsServiceProvider).markLastSuccessNow();
              } else {
                await _handleFailure(task, 'HTTP ${resp.statusCode}');
              }
            }
          } catch (e2, st2) {
            log.e('worker: PUT failed: $e2\n$st2');
            await _handleFailure(task, '$e2');
          }
        }
      } catch (e, st) {
        log.e('upload task error: $e\n$st');
        await _handleFailure(task, '$e');
      }
      await _refreshStats();
    }
  }

  Future<void> _handleFailure(UploadTask task, String error) async {
    // 简单指数退避重试：最多 3 次
    final maxRetries = 3;
    final retries = task.retries;
    if (retries < maxRetries) {
      final delay = Duration(seconds: 1 << retries); // 1,2,4
      if (kVerboseLog) log.w('retry: id=${task.id} in ${delay.inSeconds}s (retries=${retries + 1})');
      await AppDatabase.updateStatus(task.id!, TaskStatus.queued, retries: retries + 1, lastError: error);
      await Future.delayed(delay);
    } else {
      await AppDatabase.updateStatus(task.id!, TaskStatus.failed, retries: retries, lastError: error);
    }
  }

  Future<File?> _assetFile(String assetId) async {
    try {
      final entity = await AssetEntity.fromId(assetId);
      return await entity?.file;
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureRemoteDir(String baseUrl, String username, String password, String remotePath) async {
    final segments = remotePath.split('/').where((e) => e.isNotEmpty).toList();
    if (segments.length <= 1) return; // file at base, no dir to ensure
    // Build path progressively: /baseDir/albumTitle
    String path = '';
    for (int i = 0; i < segments.length - 1; i++) {
      path += '/${segments[i]}';
      final exists = await _remoteExists(baseUrl, username, password, path + '/');
      if (!exists) {
        await _mkcol(baseUrl, username, password, path + '/');
      }
    }
  }

  Future<bool> _remoteExists(String baseUrl, String username, String password, String remotePath) async {
    final uri = Uri.parse(_normalizeBaseUrl(baseUrl) + remotePath.substring(1));
    try {
      final head = await _client
          .send(http.Request('HEAD', uri)
            ..headers['Authorization'] = _basicAuth(username, password))
          .timeout(const Duration(seconds: 30));
      if (kVerboseLog) log.i('webdav: HEAD ${uri.path} -> ${head.statusCode}');
      if (head.statusCode == 200) return true;
    } catch (_) {}
    try {
      final req = http.Request('PROPFIND', uri)
        ..headers['Authorization'] = _basicAuth(username, password)
        ..headers['Depth'] = '0';
      final resp = await _client.send(req).timeout(const Duration(seconds: 45));
      if (kVerboseLog) log.i('webdav: PROPFIND ${uri.path} -> ${resp.statusCode}');
      return resp.statusCode == 207 || resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _mkcol(String baseUrl, String username, String password, String remoteDirPath) async {
    final uri = Uri.parse(_normalizeBaseUrl(baseUrl) + remoteDirPath.substring(1));
    final req = http.Request('MKCOL', uri)
      ..headers['Authorization'] = _basicAuth(username, password);
    final resp = await _client.send(req).timeout(const Duration(seconds: 30));
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    // 405 Method Not Allowed also indicates it already exists on some servers
  }

  String _normalizeBaseUrl(String baseUrl) => baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';

  String _basicAuth(String u, String p) =>
      'Basic ${base64.encode(utf8.encode('$u:$p'))}';

  Future<void> _refreshStats() async {
    final map = await AppDatabase.stats();
    final total = (map['done']! + map['failed']! + map['running']! + map['queued']!);
    state = AsyncValue.data(UploadSummary(
      total: total,
      queued: map['queued']!,
      running: map['running']!,
      done: map['done']!,
      failed: map['failed']!,
      paused: _paused,
    ));
  }
}

final uploadControllerProvider =
    StateNotifierProvider<UploadController, AsyncValue<UploadSummary>>(
        (ref) => UploadController(ref));
