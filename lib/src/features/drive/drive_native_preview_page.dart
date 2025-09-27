import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:pdfx/pdfx.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';

class DriveNativePreviewPage extends StatefulWidget {
  final String title;
  final String url; // absolute url
  final String? username;
  final String? password;
  final String? contentType; // optional hint

  const DriveNativePreviewPage({
    super.key,
    required this.title,
    required this.url,
    this.username,
    this.password,
    this.contentType,
  });

  @override
  State<DriveNativePreviewPage> createState() => _DriveNativePreviewPageState();
}

class _DriveNativePreviewPageState extends State<DriveNativePreviewPage> {
  VideoPlayerController? _video;
  PdfController? _pdf;
  Uint8List? _textBytes;
  String? _text;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  Map<String, String> get _headers {
    if ((widget.username?.isNotEmpty ?? false)) {
      final auth = base64Encode(utf8.encode('${widget.username}:${widget.password ?? ''}'));
      return {'Authorization': 'Basic $auth'};
    }
    return const {};
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _video?.dispose();
    _pdf?.dispose();
    super.dispose();
  }

  bool get _isImage => _mimeIsImage(widget.contentType) || _extIs(widget.url, const ['jpg','jpeg','png','gif','bmp','webp','heic','heif']);
  bool get _isVideo => _mimeIsVideo(widget.contentType) || _extIs(widget.url, const ['mp4','mov','m4v','webm','mkv','avi']);
  bool get _isPdf   => (widget.contentType?.contains('pdf') ?? false) || _extIs(widget.url, const ['pdf']);
  bool get _isText  => (widget.contentType?.startsWith('text/') ?? false) || _extIs(widget.url, const ['txt','log','md','json','xml','csv','yaml','yml']);

  bool _mimeIsImage(String? ct) => ct?.startsWith('image/') ?? false;
  bool _mimeIsVideo(String? ct) => ct?.startsWith('video/') ?? false;

  bool _extIs(String url, List<String> exts) {
    final p = Uri.parse(url).path.toLowerCase();
    return exts.any((e) => p.endsWith('.$e'));
  }

  Future<void> _init() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (_isVideo) {
        final c = VideoPlayerController.networkUrl(Uri.parse(widget.url), httpHeaders: _headers);
        await c.initialize();
        c.setLooping(true);
        setState(() { _video = c; _loading = false; });
        return;
      }
      if (_isPdf) {
        final bytes = await _downloadBytes(maxBytes: 20 * 1024 * 1024); // 20MB safety
        final doc = PdfDocument.openData(bytes);
        setState(() { _pdf = PdfController(document: doc); _loading = false; });
        return;
      }
      if (_isText) {
        final bytes = await _downloadBytes(maxBytes: 2 * 1024 * 1024); // 2MB
        String? decoded;
        try { decoded = utf8.decode(bytes); } catch (_) { decoded = String.fromCharCodes(bytes); }
        setState(() { _textBytes = bytes; _text = decoded; _loading = false; });
        return;
      }
      // image or fallback
      setState(() { _loading = false; });
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<Uint8List> _downloadBytes({required int maxBytes}) async {
    final resp = await http.get(Uri.parse(widget.url), headers: _headers);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    final bytes = resp.bodyBytes;
    if (bytes.length > maxBytes) {
      throw Exception('文件过大，超过预览限制');
    }
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if ((_isImage || _isText) && !_loading)
        IconButton(
          tooltip: _isImage ? '保存到相册' : '导出文件',
          onPressed: _saving ? null : () async {
            if (_isImage) {
              await _saveImageToGallery();
            } else {
              await _exportCurrent();
            }
          },
          icon: Icon(_isImage ? Icons.save_alt : Icons.ios_share),
        ),
      if ((_isImage || _isText) && !_loading)
        IconButton(
          tooltip: '分享/导出',
          onPressed: _saving ? null : _exportCurrent,
          icon: const Icon(Icons.share_outlined),
        ),
      IconButton(
        tooltip: '在浏览器打开',
        onPressed: () async {
          // ignore: deprecated_member_use
          await launchUrlString(widget.url, mode: LaunchMode.externalApplication);
        },
        icon: const Icon(Icons.open_in_new),
      ),
      IconButton(
        tooltip: '刷新',
        onPressed: _init,
        icon: const Icon(Icons.refresh),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis), actions: actions),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView(_error!)
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isVideo && _video != null && _video!.value.isInitialized) {
      final v = _video!;
      return Center(
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
            _VideoControls(v: v),
          ],
        ),
      );
    }
    if (_isPdf && _pdf != null) {
      return PdfView(controller: _pdf!);
    }
    if (_isText && _text != null) {
      return SelectableText(_text!, style: const TextStyle(fontFamily: 'monospace'));
    }
    // image or fallback
    return InteractiveViewer(
      child: Center(
        child: Image.network(
          widget.url,
          headers: _headers,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _fallbackOpenHint(),
        ),
      ),
    );
  }

  Widget _fallbackOpenHint() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file_outlined, size: 48, color: Colors.grey),
        const SizedBox(height: 8),
        const Text('无法原生预览该文件'),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () async {
            // ignore: deprecated_member_use
            await launchUrlString(widget.url, mode: LaunchMode.externalApplication);
          },
          icon: const Icon(Icons.open_in_browser),
          label: const Text('在浏览器打开'),
        ),
      ],
    );
  }

  Widget _errorView(String err) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red),
          const SizedBox(height: 8),
          Text('加载失败: $err'),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _init, icon: const Icon(Icons.refresh), label: const Text('重试')),
        ],
      ),
    );
  }

  Future<void> _saveImageToGallery() async {
    try {
      setState(() => _saving = true);
      // Download full image bytes (no limit) for saving
      final resp = await http.get(Uri.parse(widget.url), headers: _headers);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final bytes = resp.bodyBytes;
      final name = _suggestFileName(fallbackExt: 'jpg');
      final result = await ImageGallerySaver.saveImage(bytes, name: name);
      if (!mounted) return;
      final success = (result is Map && (result['isSuccess'] == true || result['isSuccess'] == 'true'));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? '已保存到相册' : '保存失败')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _exportCurrent() async {
    try {
      setState(() => _saving = true);
      Uint8List bytes;
      String mime;
      String filename;
      if (_isText) {
        if (_textBytes == null) {
          final b = await _downloadBytes(maxBytes: 2 * 1024 * 1024);
          _textBytes = b;
        }
        bytes = _textBytes!;
        mime = widget.contentType ?? 'text/plain';
        filename = _suggestFileName(fallbackExt: 'txt');
      } else if (_isImage) {
        final resp = await http.get(Uri.parse(widget.url), headers: _headers);
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('HTTP ${resp.statusCode}');
        }
        bytes = resp.bodyBytes;
        mime = widget.contentType ?? 'image/*';
        filename = _suggestFileName(fallbackExt: 'jpg');
      } else {
        return;
      }
      final tmp = await getTemporaryDirectory();
      final path = '${tmp.path}/$filename';
      final f = File(path);
      await f.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(path, mimeType: mime, name: filename)]);
      // Best-effort temp cleanup after share
      Future.delayed(const Duration(seconds: 60), () async { try { if (await f.exists()) await f.delete(); } catch (_) {} });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _suggestFileName({required String fallbackExt}) {
    String name = widget.title.trim();
    if (name.isEmpty) name = 'file';
    final hasExt = name.contains('.') && name.split('.').last.length <= 5;
    if (!hasExt) name = '$name.$fallbackExt';
    // sanitize
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return name;
  }
}

class _VideoControls extends StatefulWidget {
  final VideoPlayerController v;
  const _VideoControls({required this.v});

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  @override
  Widget build(BuildContext context) {
    final v = widget.v;
    return Container(
      color: Colors.black26,
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            color: Colors.white,
            onPressed: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
            icon: Icon(v.value.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 12),
          Text(_fmtPos(v), style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  String _fmtPos(VideoPlayerController v) {
    final d = v.value.position;
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }
}
