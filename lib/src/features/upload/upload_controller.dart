import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import '../../core/logger.dart';
import '../../core/path_utils.dart';
import '../../core/config.dart';
import '../../core/network.dart';
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
  bool _workersLaunched = false;
  final List<Future<void>> _workerFutures = [];
  bool _building = false;
  int _activeWorkers = 0;
  int _concurrency = 0; // current target concurrency
  int _maxConcurrency = 0; // cap from settings
  int _successStreak = 0;
  int _failureStreak = 0;

  // Directory and listing caches
  final Set<String> _dirEnsured = <String>{};
  final Map<String, Future<void>> _dirEnsureInflight = {};
  final Map<String, Map<String, int?>> _dirIndexCache = {};
  final Map<String, DateTime> _dirIndexAt = {};
  final Map<String, Future<Map<String, int?>>> _dirIndexInflight = {};
  final Duration _dirIndexTtl = const Duration(minutes: 5);

  @override
  void dispose() {
    try { _client.close(); } catch (_) {}
    super.dispose();
  }

  Future<void> buildPlanAndStart() async {
    if (_building) return; // 防重入
    _building = true;
    _cancelling = false;
    state = const AsyncValue.loading();
    try {
      final settings = ref.read(settingsControllerProvider).value!;
      if (!settings.isConfigured) {
        throw Exception('请先在设置中配置 WebDAV 地址与用户名');
      }
      // 确保相册权限
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.isAuth) {
        throw Exception('未获得照片权限，请在系统设置中授予相册访问权限');
      }
      log.i('buildPlan: start wifiOnly=${settings.wifiOnly} includeVideos=${settings.includeVideos} baseDir=${settings.baseRemoteDir}');
      // 仅在未有工作线程且没有 running 任务时，才重置遗留 running → queued
      try {
        final m = await AppDatabase.stats();
        if (!_workersLaunched && (m['running'] ?? 0) == 0) {
          await AppDatabase.resetRunningToQueued();
        }
      } catch (_) {}
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
        onlyAll: true,
        filterOption: filterGroup,
      );
      log.i('buildPlan: albums=${paths.length}');
      // Disambiguate albums with same display name by appending short id suffix
      final nameCount = <String, int>{};
      for (final p in paths) {
        final t = sanitizeSegment(p.name);
        nameCount[t] = (nameCount[t] ?? 0) + 1;
      }

      // Clear previous queued tasks to avoid duplication
      // Keep done/failed for history; we could clear table but here we just append.

      const pageSize = 500;
      final List<UploadTask> tasks = [];
      // Use composite key assetId|remotePath for dedupe to match DB unique constraint
      final existingPairs = await AppDatabase.existingAssetRemotePairs(
          includeQueued: true, includeRunning: true, includeDone: true);
      final seen = <String>{...existingPairs};
      int skipped = 0;
      int consecutiveSeen = 0;
      const seenBreakThreshold = 500;
      int enqueuedTotal = 0;
      void startWorkersIfNeeded() {
        if (settings.parallelScanUpload) {
          _ensureWorkersStarted(settings.maxParallelUploads);
        }
      }

      for (final p in paths) {
        var albumTitle = sanitizeSegment(p.name);
        if ((nameCount[albumTitle] ?? 0) > 1) {
          final idSuffix = p.id.length > 6 ? p.id.substring(0, 6) : p.id;
          albumTitle = sanitizeSegment('$albumTitle($idSuffix)');
        }
        int page = 0;
        while (true) {
          final assets = await p.getAssetListPaged(page: page, size: pageSize);
          if (assets.isEmpty) break;
          if (kVerboseLog) log.i('scan: album=$albumTitle page=$page size=${assets.length}');
          for (final a in assets) {
            if (_cancelling) return;
            final filename = _computeFileNameFast(a);
            final remotePath = _buildRemotePath(
              baseDir: settings.baseRemoteDir ?? '/Albums',
              albumTitle: albumTitle,
              fileName: filename,
            );
            final key = '${a.id}|$remotePath';
            if (seen.contains(key)) { skipped++; consecutiveSeen++; continue; }
            seen.add(key);
            consecutiveSeen = 0;
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
            enqueuedTotal += tasks.length;
            tasks.clear();
          }
          if (settings.incrementalOnly && consecutiveSeen >= seenBreakThreshold) {
            if (kVerboseLog) log.i('scan: break early album=$albumTitle due to seen streak=$consecutiveSeen');
            break;
          }
          if (settings.recentPages > 0 && page + 1 >= settings.recentPages) {
            if (kVerboseLog) log.i('scan: stop after recentPages=${settings.recentPages} album=$albumTitle');
            break;
          }
          page++;
        }
      }

      if (tasks.isNotEmpty) {
        await AppDatabase.insertTasks(tasks);
        await _refreshStats();
        startWorkersIfNeeded();
        enqueuedTotal += tasks.length;
        tasks.clear();
      }
      log.i('buildPlan: enqueued=$enqueuedTotal skipped=$skipped existingCached=${seen.length}');
      // 确保至少启动一次工作线程以便消费零星任务
      _ensureWorkersStarted(settings.maxParallelUploads);
      await _refreshStats();
    } catch (e, st) {
      log.e('buildPlanAndStart error: $e\n$st');
      state = AsyncValue.error(e, st);
    }
    _building = false;
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
      _ensureWorkersStarted(settings.maxParallelUploads);
      await _refreshStats();
    } catch (e, st) {
      log.e('startQueuedUploads error: $e\n$st');
      state = AsyncValue.error(e, st);
    }
  }

  void _ensureWorkersStarted(int desired) {
    _maxConcurrency = desired;
    if (_concurrency == 0) _concurrency = desired;
    if (_concurrency > _maxConcurrency) _concurrency = _maxConcurrency;
    while (_activeWorkers < _concurrency) {
      _spawnWorker();
    }
  }

  void _spawnWorker() {
    _activeWorkers++;
    _workersLaunched = true;
    final f = _worker().whenComplete(() {
      _activeWorkers--;
      if (_activeWorkers <= 0) {
        _workersLaunched = false;
      }
      _refreshStats();
    });
    _workerFutures.add(f);
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
    // Choose extension by MIME or asset type to avoid mislabeling videos.
    String ext;
    if (a.type == AssetType.video) {
      ext = 'mp4';
    } else {
      ext = 'jpg';
    }
    final mt = a.mimeType;
    if (mt != null && mt.isNotEmpty) {
      final low = mt.toLowerCase();
      if (low.startsWith('image/')) {
        if (low.contains('png')) ext = 'png';
        else if (low.contains('heic') || low.contains('heif')) ext = 'heic';
        else if (low.contains('gif')) ext = 'gif';
        else if (low.contains('jpeg') || low.contains('jpg')) ext = 'jpg';
        else if (low.contains('webp')) ext = 'webp';
      } else if (low.startsWith('video/')) {
        if (low.contains('mp4')) ext = 'mp4';
        else if (low.contains('quicktime')) ext = 'mov';
        else if (low.contains('webm')) ext = 'webm';
        else if (low.contains('x-matroska')) ext = 'mkv';
        else if (low.contains('x-msvideo')) ext = 'avi';
        else if (low.contains('3gpp')) ext = '3gp';
        else if (low.contains('3gpp2')) ext = '3g2';
        else if (low.contains('m4v')) ext = 'm4v';
        else if (low.contains('ogg')) ext = 'ogv';
        else ext = 'mp4';
      }
    }
    final original = a.title;
    if (original != null && original.isNotEmpty) {
      final s = sanitizeSegment(original);
      if (s.contains('.')) return s;
      return sanitizeSegment('$s.$ext');
    }
    final ts = a.createDateTime.millisecondsSinceEpoch;
    return sanitizeSegment('${ts}_${a.id}.$ext');
  }

  Future<void> _worker() async {
    final initial = ref.read(settingsControllerProvider).value!;
    final baseUrl = initial.baseUrl!;
    final username = initial.username!;
    final password = await ref.read(settingsServiceProvider).loadPassword() ?? '';

    while (!_cancelling) {
      // Pause gate: stop claiming new tasks while paused
      while (_paused && !_cancelling) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      // Re-check Wi‑Fi before claiming to respect runtime network changes
      final curSettings = ref.read(settingsControllerProvider).value!;
      if (curSettings.wifiOnly) {
        final wifi = await isOnWifi();
        if (!wifi) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
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

        // Check if remote exists and matches size; if exists but size differs, adjust filename
        final file = await _assetFile(task.assetId);
        if (file == null) {
          if (kVerboseLog) log.w('worker: local file not found asset=${task.assetId}');
          await _handleFailure(task, '无法访问文件');
          continue;
        }
        final size = await file.length();
        var effectiveRemotePath = task.remotePath;
        final info = await _remoteInfo(baseUrl, username, password, effectiveRemotePath);
        if (info.exists) {
          if (info.size != null && info.size == size) {
            if (kVerboseLog) log.i('worker: exists and same size, skip id=${task.id}');
            await AppDatabase.updateTotalBytes(task.id!, size);
            await AppDatabase.updateProgress(task.id!, size, TaskStatus.done);
            await ref.read(settingsServiceProvider).markLastSuccessNow();
            _onUploadSuccess();
            continue;
          } else {
            // Rename with short id suffix to avoid collision
            final alt = await _findAvailableAltPath(baseUrl, username, password, effectiveRemotePath, task.assetId);
            if (alt != effectiveRemotePath) {
              await AppDatabase.updateRemotePath(task.id!, alt);
              effectiveRemotePath = alt; // use for this run
            }
          }
        }

        if (kVerboseLog) log.i('worker: resolving local file for asset=${task.assetId}');
        if (kVerboseLog) log.i('worker: will PUT size=$size id=${task.id}');
        // Persist total size for progress UI (only once per task)
        try { await AppDatabase.updateTotalBytes(task.id!, size); } catch (_) {}
        int sent = 0;
        int lastRefresh = DateTime.now().millisecondsSinceEpoch;
        int lastDbWritten = 0;
        final dbTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
          if (sent != lastDbWritten) {
            final tmp = sent;
            lastDbWritten = tmp;
            try { await AppDatabase.updateProgress(task.id!, tmp, TaskStatus.running); } catch (_) {}
          }
        });

        final uri = Uri.parse(_normalizeBaseUrl(baseUrl) + effectiveRemotePath.substring(1));
        final req = http.StreamedRequest('PUT', uri);
        req.contentLength = size;
        req.headers['Authorization'] = _basicAuth(username, password);
        req.headers['Content-Type'] = 'application/octet-stream';
        if (kDryRun) {
          if (kVerboseLog) log.w('worker: DRY_RUN skip PUT id=${task.id}');
          await AppDatabase.updateProgress(task.id!, 0, TaskStatus.done);
          if (dbTimer.isActive) dbTimer.cancel();
        } else {
          try {
            // Strategy: small files buffered, larger files streaming with progress.
            // Lower threshold to 4MB to avoid long blocking waits without progress.
            if (size <= 4 * 1024 * 1024) {
              final bytes = await file.readAsBytes();
              if (_cancelling || _cancelled.contains(task.id!)) {
                throw _CancelledUpload();
              }
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
                _updateDirIndexAfterSuccess(effectiveRemotePath, size);
                _onUploadSuccess();
              } else {
                await _handleHttpFailure(task, r.statusCode);
              }
              if (dbTimer.isActive) dbTimer.cancel();
            } else {
              // Add explicit connection close to avoid problematic keep-alive stalls on some servers
              req.headers['Connection'] = 'close';
              // Begin sending before piping body to ensure the consumer is attached to the sink
              final mb = (size / (1024 * 1024)).ceil();
              final secs = (60 + mb * 4).clamp(60, 1800); // allow larger files
              final responseFuture = _client.send(req).timeout(Duration(seconds: secs));
              final stream = file.openRead().map((chunk) {
                if (_cancelling || _cancelled.contains(task.id!)) {
                  throw _CancelledUpload();
                }
                sent += chunk.length;
                final now = DateTime.now().millisecondsSinceEpoch;
                if (now - lastRefresh > 800) {
                  lastRefresh = now;
                  // best-effort: no await inside stream mapping
                  _refreshStats();
                }
                return chunk;
              });
              try {
                await req.sink.addStream(stream);
              } finally {
                await req.sink.close();
                dbTimer.cancel();
              }
              final resp = await responseFuture;
              if (kVerboseLog) log.i('worker: PUT(stream) status=${resp.statusCode} id=${task.id}');
              if (resp.statusCode >= 200 && resp.statusCode < 300) {
                await AppDatabase.updateProgress(task.id!, size, TaskStatus.done);
                await ref.read(settingsServiceProvider).markLastSuccessNow();
                _updateDirIndexAfterSuccess(effectiveRemotePath, size);
                _onUploadSuccess();
              } else {
                await _handleHttpFailure(task, resp.statusCode);
              }
            }
          } on _CancelledUpload {
            if (kVerboseLog) log.w('worker: cancelled id=${task.id}');
            await AppDatabase.updateStatus(task.id!, TaskStatus.failed, lastError: '用户取消');
          } catch (e2, st2) {
            log.e('worker: PUT failed: $e2\n$st2');
            final isTimeout = e2 is TimeoutException || '$e2'.toLowerCase().contains('timeout');
            await _handleFailure(task, '$e2', transient: isTimeout);
          }
        }
      } catch (e, st) {
        log.e('upload task error: $e\n$st');
        await _handleFailure(task, '$e', transient: true);
      }
      await _refreshStats();
    }
  }

  Future<void> _handleFailure(UploadTask task, String error, {bool transient = true}) async {
    final maxRetries = 3;
    final retries = task.retries;
    if (transient && retries < maxRetries) {
      final base = 1 << retries; // 1,2,4
      final jitter = (base * 0.2);
      final seconds = base + (math.Random().nextDouble() * jitter - jitter / 2);
      final delay = Duration(seconds: seconds.clamp(1, 30).round());
      if (kVerboseLog) log.w('retry: id=${task.id} in ${delay.inSeconds}s (retries=${retries + 1})');
      final newPriority = (retries + 1).clamp(0, 5);
      await AppDatabase.updateStatus(task.id!, TaskStatus.queued,
          retries: retries + 1, lastError: error, priority: newPriority);
      _onTransientFailure();
      await Future.delayed(delay);
    } else {
      await AppDatabase.updateStatus(task.id!, TaskStatus.failed,
          retries: retries, lastError: error);
    }
  }

  Future<void> _handleHttpFailure(UploadTask task, int code) async {
    if (code == 401 || code == 403) {
      await AppDatabase.updateStatus(task.id!, TaskStatus.failed, lastError: 'HTTP $code 权限/认证失败');
      return;
    }
    if (code == 413 || code == 507) {
      await AppDatabase.updateStatus(task.id!, TaskStatus.failed, lastError: 'HTTP $code 存储/大小限制');
      return;
    }
    // Transient: 429/5xx
    if (code == 429 || (code >= 500 && code < 600)) {
      await _handleFailure(task, 'HTTP $code', transient: true);
      return;
    }
    await _handleFailure(task, 'HTTP $code', transient: true);
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
    String path = '';
    for (int i = 0; i < segments.length - 1; i++) {
      path += '/${segments[i]}';
      final dirPath = path + '/';
      if (_dirEnsured.contains(dirPath)) continue;
      // de-duplicate concurrent ensure
      final inflight = _dirEnsureInflight[dirPath];
      if (inflight != null) {
        await inflight; // wait existing
        _dirEnsured.add(dirPath);
        continue;
      }
      final fut = () async {
        final exists = await _remoteExists(baseUrl, username, password, dirPath);
        if (!exists) {
          await _mkcol(baseUrl, username, password, dirPath);
        }
      }();
      _dirEnsureInflight[dirPath] = fut;
      await fut;
      _dirEnsureInflight.remove(dirPath);
      _dirEnsured.add(dirPath);
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

  Future<_RemoteInfo> _remoteInfo(String baseUrl, String username, String password, String remotePath) async {
    final uri = Uri.parse(_normalizeBaseUrl(baseUrl) + remotePath.substring(1));
    // try directory index cache first
    final parent = _parentDir(remotePath);
    final name = _basename(remotePath);
    try {
      final idx = await _getDirIndex(baseUrl, username, password, parent);
      if (idx.containsKey(name)) {
        return _RemoteInfo(true, idx[name]);
      }
    } catch (_) {}
    try {
      final req = http.Request('HEAD', uri)
        ..headers['Authorization'] = _basicAuth(username, password);
      final head = await _client.send(req).timeout(const Duration(seconds: 30));
      if (head.statusCode == 200) {
        final len = head.headers['content-length'];
        return _RemoteInfo(true, len != null ? int.tryParse(len) : null);
      }
    } catch (_) {}
    try {
      final req = http.Request('PROPFIND', uri)
        ..headers['Authorization'] = _basicAuth(username, password)
        ..headers['Depth'] = '0';
      final resp = await _client.send(req).timeout(const Duration(seconds: 45));
      if (resp.statusCode == 207 || resp.statusCode == 200) {
        final body = await resp.stream.bytesToString();
        final contentLenRe = RegExp(r'<(?:[a-zA-Z]+:)?getcontentlength\b[^>]*>(\d+)<\/(?:[a-zA-Z]+:)?getcontentlength>');
        final m = contentLenRe.firstMatch(body);
        final size = m != null ? int.tryParse(m.group(1)!) : null;
        return _RemoteInfo(true, size);
      }
    } catch (_) {}
    return const _RemoteInfo(false, null);
  }

  Future<Map<String, int?>> _getDirIndex(String baseUrl, String username, String password, String dirPath) async {
    final now = DateTime.now();
    final freshAt = _dirIndexAt[dirPath];
    if (freshAt != null && now.difference(freshAt) < _dirIndexTtl) {
      final cached = _dirIndexCache[dirPath];
      if (cached != null) return cached;
    }
    final inflight = _dirIndexInflight[dirPath];
    if (inflight != null) return await inflight;
    final future = _fetchDirIndex(baseUrl, username, password, dirPath);
    _dirIndexInflight[dirPath] = future;
    try {
      final map = await future;
      _dirIndexCache[dirPath] = map;
      _dirIndexAt[dirPath] = DateTime.now();
      return map;
    } finally {
      _dirIndexInflight.remove(dirPath);
    }
  }

  Future<Map<String, int?>> _fetchDirIndex(String baseUrl, String username, String password, String dirPath) async {
    final uri = Uri.parse(_normalizeBaseUrl(baseUrl) + dirPath.substring(1));
    final req = http.Request('PROPFIND', uri)
      ..headers['Authorization'] = _basicAuth(username, password)
      ..headers['Depth'] = '1';
    final resp = await _client.send(req).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 207 && resp.statusCode != 200) {
      return {};
    }
    final xml = await resp.stream.bytesToString();
    final responseRe = RegExp(r'<(?:[a-zA-Z]+:)?response\b[\s\S]*?<\/(?:[a-zA-Z]+:)?response>', multiLine: true);
    final hrefRe = RegExp(r'<(?:[a-zA-Z]+:)?href\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?href>');
    final contentLenRe = RegExp(r'<(?:[a-zA-Z]+:)?getcontentlength\b[^>]*>(\d+)<\/(?:[a-zA-Z]+:)?getcontentlength>');
    final reqPath = Uri.parse(_normalizeBaseUrl(baseUrl) + dirPath.substring(1)).path;
    final String basePath = reqPath.endsWith('/') ? reqPath : '$reqPath/';
    final map = <String, int?>{};
    for (final m in responseRe.allMatches(xml)) {
      final block = xml.substring(m.start, m.end);
      final hrefM = hrefRe.firstMatch(block);
      if (hrefM == null) continue;
      var href = hrefM.group(1)!.trim().replaceAll('&amp;', '&');
      Uri? u;
      try { u = Uri.parse(href); } catch (_) {}
      final path = (u?.hasAuthority ?? false) ? (u!.path) : href;
      final hPath = _safeDecode(path);
      // skip self
      if (_pathsEquivalent(hPath.endsWith('/') ? hPath : '$hPath/', basePath)) continue;
      // relative name (first segment only)
      String rel;
      if (hPath.startsWith(basePath)) {
        rel = hPath.substring(basePath.length);
      } else {
        rel = hPath.split('/').where((e) => e.isNotEmpty).isNotEmpty
            ? hPath.split('/').where((e) => e.isNotEmpty).last
            : hPath;
      }
      if (rel.startsWith('/')) rel = rel.substring(1);
      if (rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);
      final name = _safeDecode(rel);
      final lenStr = contentLenRe.firstMatch(block)?.group(1);
      final size = lenStr != null ? int.tryParse(lenStr) : null;
      map[name] = size;
    }
    return map;
  }

  void _updateDirIndexAfterSuccess(String remotePath, int size) {
    final dir = _parentDir(remotePath);
    final name = _basename(remotePath);
    final map = _dirIndexCache[dir] ?? <String, int?>{};
    map[name] = size;
    _dirIndexCache[dir] = map;
    _dirIndexAt[dir] = DateTime.now();
  }

  String _parentDir(String remotePath) {
    final parts = remotePath.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length <= 1) return '/';
    return '/${parts.sublist(0, parts.length - 1).join('/')}/';
  }

  String _basename(String remotePath) {
    final parts = remotePath.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return remotePath;
    try { return Uri.decodeComponent(parts.last); } catch (_) { return parts.last; }
  }

  bool _pathsEquivalent(String a, String b) {
    String n(String s) => s.replaceAll(RegExp(r'/+'), '/');
    return n(a) == n(b);
  }

  String _safeDecode(String s) { try { return Uri.decodeComponent(s); } catch (_) { return s; } }

  void _onUploadSuccess() {
    _successStreak++;
    if (_successStreak >= 5 && _concurrency < _maxConcurrency) {
      _concurrency++;
      _successStreak = 0;
      // spawn extra worker if needed
      if (_activeWorkers < _concurrency) {
        _spawnWorker();
      }
    }
  }

  void _onTransientFailure() {
    _successStreak = 0;
    _failureStreak++;
    if (_concurrency > 1) {
      _concurrency--;
    }
  }

  Future<String> _findAvailableAltPath(String baseUrl, String username, String password, String remotePath, String assetId) async {
    // Append suffix before extension; try a few variants
    String suffixBase = '_${assetId.length > 8 ? assetId.substring(0, 8) : assetId}';
    for (int i = 0; i < 5; i++) {
      final suffix = i == 0 ? suffixBase : '${suffixBase}_$i';
      final alt = _appendSuffixToRemoteFilePath(remotePath, suffix);
      final exist = await _remoteExists(baseUrl, username, password, alt);
      if (!exist) return alt;
    }
    return remotePath; // give up
  }

  String _appendSuffixToRemoteFilePath(String remotePath, String suffix) {
    final parts = remotePath.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return remotePath;
    final fileEnc = parts.removeLast();
    String file;
    try { file = Uri.decodeComponent(fileEnc); } catch (_) { file = fileEnc; }
    final dot = file.lastIndexOf('.');
    final base = dot > 0 ? file.substring(0, dot) : file;
    final ext = dot > 0 ? file.substring(dot + 1) : '';
    final newName = ext.isNotEmpty ? '$base$suffix.$ext' : '$base$suffix';
    final segs = [...parts.map((e) { try { return Uri.decodeComponent(e); } catch (_) { return e; } }), sanitizeSegment(newName)];
    return joinUrlSegments(segs);
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

class _RemoteInfo {
  final bool exists;
  final int? size;
  const _RemoteInfo(this.exists, this.size);
}

class _CancelledUpload implements Exception {}

final uploadControllerProvider =
    StateNotifierProvider<UploadController, AsyncValue<UploadSummary>>(
        (ref) => UploadController(ref));
