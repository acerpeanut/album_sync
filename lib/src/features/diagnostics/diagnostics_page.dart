import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../services/settings_service.dart';
import '../../services/webdav_service.dart';
import '../../services/temp_cleaner.dart';
import '../../services/remote_indexer.dart';
import '../../core/server_key.dart';

final _statsProvider = FutureProvider<Map<String, int>>((ref) async {
  return AppDatabase.stats();
});

final _failedProvider = FutureProvider<List<UploadTask>>((ref) async {
  final db = await AppDatabase.instance();
  final rows = await db.query('upload_tasks',
      where: 'status = ?',
      whereArgs: [TaskStatus.failed.name],
      orderBy: 'updatedAt DESC',
      limit: 50);
  return rows.map(UploadTask.fromMap).toList();
});

class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(_statsProvider);
    final settings = ref.watch(settingsControllerProvider);
    final failed = ref.watch(_failedProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('诊断与日志')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          settings.when(
            data: (s) => Text('去重(哈希)：${s.enableContentHash ? '开' : '关'}  Wi‑Fi算哈希：${s.hashWifiOnly ? '是' : '否'}  启动引导：${s.bootstrapRemoteIndex ? '开' : '关'}  允许MOVE：${s.allowReorganizeMove ? '是' : '否'}'),
            loading: () => const SizedBox.shrink(),
            error: (e, st) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 8),
          stats.when(
            data: (m) => Text('统计：总=${m['done']! + m['failed']! + m['running']! + m['queued']!}  完成=${m['done']}  失败=${m['failed']}  进行中=${m['running']}  队列=${m['queued']}'),
            loading: () => const Text('统计载入中…'),
            error: (e, st) => Text('统计出错: $e'),
          ),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
              onPressed: () async {
                final usage = await ref.read(tempCleanerProvider).measureUsage();
                if (context.mounted) {
                  final mb = (usage.tmpBytes / (1024 * 1024)).toStringAsFixed(2);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('临时目录占用约 ${mb}MB，文件数 ${usage.files}')));
                }
              },
              child: const Text('测量临时占用'),
            ),
            FilledButton(
              onPressed: () async {
                final rep = await ref.read(tempCleanerProvider).cleanTemp();
                if (context.mounted) {
                  final mb = (rep.freedBytes / (1024 * 1024)).toStringAsFixed(2);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已清理 ${rep.deletedFiles} 个临时文件，释放 ${mb}MB')));
                }
              },
              child: const Text('清理临时文件'),
            ),
            FilledButton(
              onPressed: () async {
                await AppDatabase.resetRunningToQueued();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已将 running 任务重置为 queued')));
                }
                ref.invalidate(_statsProvider);
              },
              child: const Text('重置进行中任务'),
            ),
            FilledButton(
              onPressed: () async {
                final s = ref.read(settingsControllerProvider).value;
                if (s == null || !s.isConfigured) return;
                final pwd = await ref.read(settingsServiceProvider).loadPassword() ?? '';
                final idx = ref.read(remoteIndexerProvider);
                final n = await idx.bootstrap(
                  baseUrl: s.baseUrl!,
                  username: s.username!,
                  password: pwd,
                  baseRemoteDir: s.baseRemoteDir ?? '/',
                );
                if (context.mounted) {
                  final key = buildServerKey(s.baseUrl!, s.username!);
                  final cnt = await AppDatabase.remoteIndexCount(key);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('索引完成: 本次 $n 项，累计 $cnt 项')));
                }
                await ref.read(settingsControllerProvider.notifier).markRemoteIndexNow();
              },
              child: const Text('重建远端哈希索引'),
            ),
            FilledButton(
              onPressed: () async {
                final n = await AppDatabase.repairRemotePaths();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已修复 $n 条路径编码（队列/进行中/失败）')));
                }
                ref.invalidate(_statsProvider);
                ref.invalidate(_failedProvider);
              },
              child: const Text('修复队列路径编码'),
            ),
            FilledButton(
              onPressed: () async {
                await AppDatabase.cleanupQueuedDuplicates();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清理队列重复项')));
                }
                ref.invalidate(_statsProvider);
              },
              child: const Text('清理重复队列'),
            ),
            FilledButton(
              onPressed: () async {
                final db = await AppDatabase.instance();
                await db.delete('upload_tasks', where: 'status = ?', whereArgs: [TaskStatus.queued.name]);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空队列')));
                }
                ref.invalidate(_statsProvider);
                ref.invalidate(_failedProvider);
              },
              child: const Text('清空队列'),
            ),
            OutlinedButton(
              onPressed: () async {
                final n = await AppDatabase.pruneTasks();
                await AppDatabase.vacuum();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已清理历史任务 $n 条，并压缩数据库')));
                }
                ref.invalidate(_statsProvider);
                ref.invalidate(_failedProvider);
              },
              child: const Text('清理历史任务并VACUUM'),
            ),
            FilledButton(
              onPressed: () async {
                final settings = ref.read(settingsControllerProvider).value;
                if (settings == null) return;
                final ok = await ref.read(webDavServiceProvider).validateCredentials(
                      baseUrl: settings.baseUrl ?? '',
                      username: settings.username ?? '',
                      password: await ref.read(settingsServiceProvider).loadPassword() ?? '',
                    );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'WebDAV连通性正常' : 'WebDAV连通性失败')));
                }
              },
              child: const Text('测试 WebDAV 连通性'),
            ),
          ]),
          const SizedBox(height: 16),
          const Text('最近失败（最多50条）：'),
          const SizedBox(height: 8),
          failed.when(
            data: (list) => Column(
              children: list
                  .map((t) => ListTile(
                        leading: const Icon(Icons.error_outline, color: Colors.red),
                        title: Text(t.remotePath, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(t.lastError ?? '未知错误'),
                      ))
                  .toList(),
            ),
            loading: () => const Text('载入中…'),
            error: (e, st) => Text('载入失败记录出错: $e'),
          ),
        ],
      ),
    );
  }
}
