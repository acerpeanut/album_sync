import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../services/settings_service.dart';
import 'upload_controller.dart';
import 'failures_page.dart';
import '../../data/db.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter/services.dart';

class UploadPage extends ConsumerStatefulWidget {
  const UploadPage({super.key});

  @override
  ConsumerState<UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends ConsumerState<UploadPage> {
  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    // Start building plan and upload
    Future.microtask(() => ref.read(uploadControllerProvider.notifier).buildPlanAndStart());
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(uploadControllerProvider);
    final settingsAsync = ref.watch(settingsControllerProvider);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('正在上传'),
          actions: [
            IconButton(
              onPressed: () => ref.read(uploadControllerProvider.notifier).cancel(),
              tooltip: '取消全部',
              icon: const Icon(Icons.stop_circle_outlined),
            )
          ],
          bottom: const TabBar(tabs: [
            Tab(text: '队列'),
            Tab(text: '进行中'),
            Tab(text: '失败'),
            Tab(text: '完成'),
          ]),
        ),
        body: Center(
          child: summaryAsync.when(
            data: (s) {
              final total = s.total == 0 ? 1 : s.total;
              final progressed = s.done + s.failed;
              final percent = (progressed / total).clamp(0.0, 1.0);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(value: percent),
                      const SizedBox(height: 8),
                      Text('总计:${s.total}  完成:${s.done}  失败:${s.failed}  进行中:${s.running}  队列:${s.queued}')
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _TasksList(status: TaskStatus.queued, onDelete: (id) => ref.read(uploadControllerProvider.notifier).deleteOne(id)),
                      _TasksList(status: TaskStatus.running,
                          onDelete: (id) => ref.read(uploadControllerProvider.notifier).deleteOne(id),
                          onCancel: (id) => ref.read(uploadControllerProvider.notifier).cancelOne(id)),
                      _TasksList(status: TaskStatus.failed, onRetry: (id) => ref.read(uploadControllerProvider.notifier).requeueOne(id), onDelete: (id) => ref.read(uploadControllerProvider.notifier).deleteOne(id)),
                      _TasksList(status: TaskStatus.done, baseUrl: settingsAsync.asData?.value.baseUrl ?? ''),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      FilledButton.icon(
                        onPressed: summaryAsync.isLoading ? null : () => ref.read(uploadControllerProvider.notifier).buildPlanAndStart(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新扫描并上传'),
                      ),
                      FilledButton.icon(
                        onPressed: () => ref.read(uploadControllerProvider.notifier).startQueuedUploads(),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('仅上传当前队列'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: settingsAsync.when(
                    data: (set) => Text('目标: ${set.baseUrl ?? ''}${set.baseRemoteDir ?? '/Albums'}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    loading: () => const SizedBox.shrink(),
                    error: (e, st) => const SizedBox.shrink(),
                  ),
                ),
              ],
            );
          },
          loading: () => const CircularProgressIndicator(),
          error: (e, st) => Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red),
                const SizedBox(height: 8),
                Text('出错: $e'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => ref.read(uploadControllerProvider.notifier).buildPlanAndStart(),
                  child: const Text('重试'),
                )
              ],
            ),
          ),
        ),
      ),
    ));
  }
}

class _TasksList extends StatefulWidget {
  final TaskStatus status;
  final void Function(int id)? onRetry;
  final void Function(int id)? onDelete;
  final void Function(int id)? onCancel;
  final String? baseUrl; // for done list to open/copy
  const _TasksList({required this.status, this.onRetry, this.onDelete, this.onCancel, this.baseUrl});

  @override
  State<_TasksList> createState() => _TasksListState();
}

class _TasksListState extends State<_TasksList> {
  List<UploadTask> _items = const [];
  bool _loading = true;
  String? _error;
  late final Timer _timer;

  Future<void> _load() async {
    final first = !_initialized;
    if (first) setState(() { _loading = true; _error = null; });
    try {
      final list = await AppDatabase.listByStatus(widget.status, limit: 500);
      setState(() { _items = list; _loading = false; _initialized = true; });
    } catch (e) {
      setState(() { _loading = false; _error = '$e'; _initialized = true; });
    }
  }

  bool _initialized = false;
  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('加载失败: ${_error}'));
    if (_items.isEmpty) return const Center(child: Text('暂无数据'));
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = _items[i];
        final full = t.remotePath;
        final name = _basenameOfRemote(full);
        final parent = _parentDirOfRemote(full);
        final displayFull = _displayPath(full);
        return ListTile(
          dense: true,
          title: Tooltip(
            message: displayFull,
            child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          subtitle: Text(
            '${t.albumTitle.isNotEmpty ? '相册:${t.albumTitle} · ' : ''}${parent.isNotEmpty ? parent : '/'}\n'
            'id=${t.id} size=${t.bytesTotal} sent=${t.bytesSent} status=${t.status.name}${t.lastError != null ? ' err=${t.lastError}' : ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          onTap: () => _showDetails(context, t, widget.baseUrl),
          trailing: Wrap(spacing: 8, children: [
            if (widget.onRetry != null)
              OutlinedButton(onPressed: () => widget.onRetry!(t.id!), child: const Text('重试')),
            if (widget.onCancel != null)
              OutlinedButton(onPressed: () => widget.onCancel!(t.id!), child: const Text('取消')),
            if (widget.onDelete != null)
              OutlinedButton(onPressed: () => widget.onDelete!(t.id!), child: const Text('删除')),
            if (widget.status == TaskStatus.done && (widget.baseUrl?.isNotEmpty ?? false))
              OutlinedButton(
                onPressed: () async {
                  final url = _buildUrl(widget.baseUrl!, t.remotePath);
                  await _openUrl(url);
                },
                child: const Text('打开'),
              ),
            if (widget.status == TaskStatus.done && (widget.baseUrl?.isNotEmpty ?? false))
              OutlinedButton(
                onPressed: () => _copyUrl(context, _buildUrl(widget.baseUrl!, t.remotePath)),
                child: const Text('复制链接'),
              ),
          ]),
        );
      },
    );
  }

  String _basenameOfRemote(String p) {
    final parts = p.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return p;
    final last = parts.last;
    return _safeDecode(last);
  }

  String _parentDirOfRemote(String p) {
    final parts = p.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length <= 1) return '/';
    final parentSegs = parts.sublist(0, parts.length - 1).map(_safeDecode).toList();
    final parent = parentSegs.join('/');
    return '/$parent';
  }

  String _displayPath(String p) {
    final segs = p.split('/').where((e) => e.isNotEmpty).map(_safeDecode).toList();
    return '/${segs.join('/')}';
  }

  String _safeDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  void _showDetails(BuildContext context, UploadTask t, String? baseUrl) {
    final name = _basenameOfRemote(t.remotePath);
    final fullPath = _displayPath(t.remotePath);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('文件名', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            SelectableText(name),
            const SizedBox(height: 12),
            const Text('完整路径', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            SelectableText(fullPath),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: name));
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件名已复制')));
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制文件名'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: fullPath));
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('路径已复制')));
                },
                icon: const Icon(Icons.content_paste),
                label: const Text('复制完整路径'),
              ),
              if (t.status == TaskStatus.done && (baseUrl?.isNotEmpty ?? false))
                OutlinedButton.icon(
                  onPressed: () async {
                    final url = _buildUrl(baseUrl!, t.remotePath);
                    await _openUrl(url);
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('打开链接'),
                ),
            ]),
          ],
        ),
      ),
    );
  }

  String _buildUrl(String base, String remotePath) {
    final b = base.endsWith('/') ? base : '$base/';
    return b + (remotePath.startsWith('/') ? remotePath.substring(1) : remotePath);
  }

  Future<void> _openUrl(String url) async {
    try {
      // ignore: deprecated_member_use
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _copyUrl(BuildContext context, String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('链接已复制')));
  }
}
