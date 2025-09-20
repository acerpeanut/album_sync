import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/settings_service.dart';
import '../../services/webdav_service.dart';
import 'drive_webview_page.dart';
import 'drive_native_preview_page.dart';

class DriveBrowserPage extends ConsumerStatefulWidget {
  const DriveBrowserPage({super.key});

  @override
  ConsumerState<DriveBrowserPage> createState() => _DriveBrowserPageState();
}

class _DriveBrowserPageState extends ConsumerState<DriveBrowserPage> {
  String? _baseUrl;
  String? _username;
  String? _password;
  String _currentPath = '/';
  Future<List<WebDavEntry>>? _future;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final s = ref.read(settingsControllerProvider).value;
    if (s == null || !s.isConfigured) {
      setState(() {
        _future = Future.error('请先在设置中配置服务器');
      });
      return;
    }
    final pwd = await ref.read(settingsServiceProvider).loadPassword() ?? '';
    setState(() {
      _baseUrl = s.baseUrl;
      _username = s.username;
      _password = pwd;
      _currentPath = _normalizeRemotePath(s.baseRemoteDir ?? '/');
      _future = _loadDir();
    });
  }

  Future<List<WebDavEntry>> _loadDir() async {
    final base = _baseUrl!;
    final user = _username!;
    final pass = _password ?? '';
    return ref.read(webDavServiceProvider).listDirectory(
          baseUrl: base,
          username: user,
          password: pass,
          remotePath: _currentPath,
        );
  }

  String _normalizeRemotePath(String path) {
    var p = path.trim();
    if (!p.startsWith('/')) p = '/$p';
    if (!p.endsWith('/')) p = '$p/';
    p = p.replaceAll(RegExp(r'/+'), '/');
    return p;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网盘浏览'),
        actions: [
          IconButton(
            tooltip: '上一级',
            onPressed: _canGoUp ? _goUp : null,
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => setState(() => _future = _loadDir()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _future == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                setState(() => _future = _loadDir());
                await _future; // wait for reload
              },
              child: FutureBuilder<List<WebDavEntry>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      children: [
                        const SizedBox(height: 120),
                        Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey.shade600),
                        const SizedBox(height: 12),
                        Center(child: Text('加载失败: ${snapshot.error}')),
                        const SizedBox(height: 8),
                        Center(
                          child: OutlinedButton(
                            onPressed: () => setState(() => _future = _loadDir()),
                            child: const Text('重试'),
                          ),
                        )
                      ],
                    );
                  }
                  final items = snapshot.data ?? const [];
                  if (items.isEmpty) {
                    return ListView(
                      children: [
                        _buildBreadcrumb(),
                        const SizedBox(height: 48),
                        const Center(child: Text('空目录')),
                      ],
                    );
                  }
                  return ListView.separated(
                    itemCount: items.length + 1,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index == 0) return _buildBreadcrumb();
                      final e = items[index - 1];
                      return ListTile(
                        leading: Icon(e.isDirectory ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
                        title: Text(e.name),
                        subtitle: e.isDirectory ? null : Text(_buildSubtitle(e)),
                        onTap: e.isDirectory ? () => _enter(e) : () => _openFile(e),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) => _handleAction(v, e),
                          itemBuilder: (_) => [
                            if (e.isDirectory)
                              const PopupMenuItem(value: 'enter', child: Text('打开')),
                            if (!e.isDirectory)
                              const PopupMenuItem(value: 'native', child: Text('原生预览')),
                            if (!e.isDirectory)
                              const PopupMenuItem(value: 'preview', child: Text('内嵌预览')),
                            if (!e.isDirectory)
                              const PopupMenuItem(value: 'download', child: Text('下载/保存')),
                            const PopupMenuItem(value: 'rename', child: Text('重命名')),
                            const PopupMenuItem(value: 'delete', child: Text('删除')),
                            if (!e.isDirectory)
                              const PopupMenuItem(value: 'open', child: Text('用浏览器打开')),
                            const PopupMenuItem(value: 'copy', child: Text('复制链接')),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
      floatingActionButton: _future == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _createFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('新建文件夹'),
            ),
    );
  }

  Widget _buildBreadcrumb() {
    final segs = _currentPath.split('/').where((e) => e.isNotEmpty).toList();
    final List<Widget> chips = [];
    String pathAcc = '/';
    for (int i = 0; i < segs.length; i++) {
      final s = segs[i];
      pathAcc = pathAcc.endsWith('/') ? '$pathAcc$s/' : '$pathAcc/$s/';
      chips.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: ActionChip(
          label: Text(s),
          onPressed: () {
            setState(() {
              _currentPath = pathAcc;
              _future = _loadDir();
            });
          },
        ),
      ));
      if (i < segs.length - 1) {
        chips.add(const Text(' / '));
      }
    }
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Icon(Icons.folder_open),
        const SizedBox(width: 8),
        if (chips.isEmpty) const Text('/') else ...chips,
      ]),
    );
  }

  bool get _canGoUp {
    final segs = _currentPath.split('/').where((e) => e.isNotEmpty).toList();
    return segs.length > 1; // allow leaving base root but keep at least one segment
  }

  void _goUp() {
    final segs = _currentPath.split('/').where((e) => e.isNotEmpty).toList();
    if (segs.isEmpty) return;
    segs.removeLast();
    final p = '/' + segs.join('/') + '/';
    setState(() {
      _currentPath = p.replaceAll(RegExp(r'/+'), '/');
      _future = _loadDir();
    });
  }

  void _enter(WebDavEntry e) {
    setState(() {
      _currentPath = _normalizeRemotePath('${_currentPath}${e.name}');
      _future = _loadDir();
    });
  }

  String _buildSubtitle(WebDavEntry e) {
    final size = e.size;
    final ts = e.lastModified != null ? _fmtTime(e.lastModified!) : '';
    if (size != null && ts.isNotEmpty) return '${_fmtSize(size)} · $ts';
    if (size != null) return _fmtSize(size);
    return ts;
  }

  String _fmtSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double b = bytes.toDouble();
    int i = 0;
    while (b >= 1024 && i < units.length - 1) { b /= 1024; i++; }
    return '${b.toStringAsFixed(b >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  String _fmtTime(DateTime dt) {
    return '${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}';
    }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  Future<void> _handleAction(String v, WebDavEntry e) async {
    switch (v) {
      case 'enter':
        if (e.isDirectory) _enter(e);
        break;
      case 'native':
        _openNativePreview(e);
        break;
      case 'preview':
        _openInWebView(e);
        break;
      case 'rename':
        await _renameEntry(e);
        break;
      case 'delete':
        await _deleteEntry(e);
        break;
      case 'open':
        await _openFile(e);
        break;
      case 'copy':
        _copyLink(e);
        break;
      case 'download':
        if (_isImage(e)) {
          await _saveImage(e);
        } else {
          await _exportAny(e);
        }
        break;
    }
  }

  Future<void> _createFolder() async {
    final name = await _promptText(context, title: '新建文件夹', hint: '输入名称');
    if (name == null || name.trim().isEmpty) return;
    final dest = _normalizeRemotePath(_currentPath + name.trim());
    try {
      await ref.read(webDavServiceProvider).mkcol(
            baseUrl: _baseUrl!,
            username: _username!,
            password: _password ?? '',
            remoteDirPath: dest,
          );
      setState(() => _future = _loadDir());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('创建成功')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败: $e')));
    }
  }

  Future<void> _renameEntry(WebDavEntry e) async {
    final name = await _promptText(context, title: '重命名', initial: e.name);
    if (name == null || name.trim().isEmpty || name == e.name) return;
    final parent = _currentPath;
    final dest = (parent.endsWith('/') ? parent : '$parent/') + name.trim();
    final destPath = e.isDirectory ? _normalizeRemotePath(dest) : dest;
    try {
      await ref.read(webDavServiceProvider).renameOrMove(
            baseUrl: _baseUrl!,
            username: _username!,
            password: _password ?? '',
            srcRemotePath: e.remotePath,
            destRemotePath: destPath,
          );
      setState(() => _future = _loadDir());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已重命名')));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重命名失败: $err')));
    }
  }

  Future<void> _deleteEntry(WebDavEntry e) async {
    final ok = await _confirm(context, '确认删除“${e.name}”吗？');
    if (!ok) return;
    try {
      await ref.read(webDavServiceProvider).remove(
            baseUrl: _baseUrl!,
            username: _username!,
            password: _password ?? '',
            remotePath: e.remotePath,
          );
      setState(() => _future = _loadDir());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除成功')));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $err')));
    }
  }

  Future<void> _openFile(WebDavEntry e) async {
    final url = _buildUrl(_baseUrl!, e.remotePath);
    try {
      // ignore: deprecated_member_use
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _openInWebView(WebDavEntry e) {
    final url = _buildUrl(_baseUrl!, e.remotePath);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DriveWebViewPage(
          title: e.name,
          url: url,
          username: _username,
          password: _password,
        ),
      ),
    );
  }

  void _openNativePreview(WebDavEntry e) {
    final url = _buildUrl(_baseUrl!, e.remotePath);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DriveNativePreviewPage(
          title: e.name,
          url: url,
          username: _username,
          password: _password,
          contentType: e.contentType,
        ),
      ),
    );
  }

  // --- Download helpers ---
  Map<String, String> get _headers {
    if ((_username?.isNotEmpty ?? false)) {
      final auth = base64Encode(utf8.encode('${_username}:${_password ?? ''}'));
      return {'Authorization': 'Basic $auth'};
    }
    return const {};
  }

  bool _isImage(WebDavEntry e) {
    final ct = e.contentType ?? '';
    if (ct.startsWith('image/')) return true;
    final n = e.name.toLowerCase();
    return n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png') || n.endsWith('.gif') || n.endsWith('.webp') || n.endsWith('.bmp') || n.endsWith('.heic') || n.endsWith('.heif');
  }

  bool _isText(WebDavEntry e) {
    final ct = e.contentType ?? '';
    if (ct.startsWith('text/')) return true;
    final n = e.name.toLowerCase();
    return n.endsWith('.txt') || n.endsWith('.log') || n.endsWith('.md') || n.endsWith('.json') || n.endsWith('.xml') || n.endsWith('.csv') || n.endsWith('.yaml') || n.endsWith('.yml');
  }

  Future<void> _saveImage(WebDavEntry e) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final url = _buildUrl(_baseUrl!, e.remotePath);
      final resp = await http.get(Uri.parse(url), headers: _headers);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final result = await ImageGallerySaver.saveImage(resp.bodyBytes, name: _sanitizeFilename(e.name));
      final success = (result is Map && (result['isSuccess'] == true || result['isSuccess'] == 'true'));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success ? '已保存到相册' : '保存失败')));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $err')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _exportFile(WebDavEntry e) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final url = _buildUrl(_baseUrl!, e.remotePath);
      final resp = await http.get(Uri.parse(url), headers: _headers);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      // Limit text export to 2MB to avoid heavy memory usage
      final bytes = resp.bodyBytes;
      if (bytes.length > 2 * 1024 * 1024) {
        throw Exception('文件过大（>2MB），请使用原生预览或浏览器保存');
      }
      final tmp = await getTemporaryDirectory();
      final filename = _ensureExt(_sanitizeFilename(e.name), fallback: 'txt');
      final path = '${tmp.path}/$filename';
      final f = File(path);
      await f.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(path, name: filename)]);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $err')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _exportAny(WebDavEntry e) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final url = _buildUrl(_baseUrl!, e.remotePath);
      final filename = _sanitizeFilename(e.name);
      final path = await _downloadToTemp(url, filename: filename, maxBytes: 512 * 1024 * 1024);
      final mime = _mimeFromNameAndCT(filename, e.contentType);
      await Share.shareXFiles([XFile(path, name: filename, mimeType: mime)]);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $err')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String> _downloadToTemp(String url, {required String filename, int? maxBytes}) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      _headers.forEach((k, v) => req.headers[k] = v);
      final resp = await client.send(req);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final tmp = await getTemporaryDirectory();
      final path = '${tmp.path}/$filename';
      final file = File(path);
      final sink = file.openWrite();
      int received = 0;
      await for (final chunk in resp.stream) {
        received += chunk.length;
        if (maxBytes != null && received > maxBytes) {
          await sink.close();
          if (await file.exists()) {
            await file.delete();
          }
          throw Exception('文件过大，超过限制');
        }
        sink.add(chunk);
      }
      await sink.close();
      return path;
    } finally {
      client.close();
    }
  }

  String _mimeFromNameAndCT(String name, String? ct) {
    if (ct != null && ct.isNotEmpty) return ct;
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.bmp')) return 'image/bmp';
    if (n.endsWith('.heic')) return 'image/heic';
    if (n.endsWith('.heif')) return 'image/heif';
    if (n.endsWith('.mp4')) return 'video/mp4';
    if (n.endsWith('.mov')) return 'video/quicktime';
    if (n.endsWith('.webm')) return 'video/webm';
    if (n.endsWith('.mkv')) return 'video/x-matroska';
    if (n.endsWith('.avi')) return 'video/x-msvideo';
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.txt') || n.endsWith('.log')) return 'text/plain';
    if (n.endsWith('.md')) return 'text/markdown';
    if (n.endsWith('.json')) return 'application/json';
    if (n.endsWith('.xml')) return 'application/xml';
    if (n.endsWith('.csv')) return 'text/csv';
    if (n.endsWith('.yaml') || n.endsWith('.yml')) return 'text/yaml';
    return 'application/octet-stream';
  }

  String _sanitizeFilename(String name) {
    var n = name.trim();
    if (n.isEmpty) n = 'file';
    n = n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return n;
  }

  String _ensureExt(String name, {required String fallback}) {
    if (name.contains('.')) return name;
    return '$name.$fallback';
  }

  void _copyLink(WebDavEntry e) {
    final url = _buildUrl(_baseUrl!, e.remotePath);
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('链接已复制')));
  }

  String _buildUrl(String base, String remotePath) {
    final b = base.endsWith('/') ? base : '$base/';
    return b + (remotePath.startsWith('/') ? remotePath.substring(1) : remotePath);
  }
}

Future<String?> _promptText(BuildContext context, {required String title, String? hint, String? initial}) async {
  final ctrl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        decoration: InputDecoration(hintText: hint ?? ''),
        autofocus: true,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(context).pop(ctrl.text.trim()), child: const Text('确定')),
      ],
    ),
  );
}

Future<bool> _confirm(BuildContext context, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('确认'),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
      ],
    ),
  );
  return ok ?? false;
}
