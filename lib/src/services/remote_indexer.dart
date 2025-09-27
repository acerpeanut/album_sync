import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../core/logger.dart';
import '../core/server_key.dart';
import '../data/db.dart';

class RemoteIndexer {
  RemoteIndexer(this._client);

  final http.Client _client;

  Future<int> bootstrap({
    required String baseUrl,
    required String username,
    required String password,
    required String baseRemoteDir,
  }) async {
    final serverKey = buildServerKey(baseUrl, username);
    final normalizedBase = _normalizeBase(baseUrl);
    final start = baseRemoteDir.startsWith('/') ? baseRemoteDir : '/$baseRemoteDir';
    final root = start.endsWith('/') ? start : '$start/';
    int filesIndexed = 0;
    // Try manifest fast-path first
    try {
      filesIndexed += await _importManifest(normalizedBase, username, password, root, serverKey);
      if (filesIndexed > 0) {
        return filesIndexed;
      }
    } catch (_) {}
    final q = <String>[root];
    final visited = <String>{};
    while (q.isNotEmpty) {
      final dir = q.removeAt(0);
      if (visited.contains(dir)) continue;
      visited.add(dir);
      try {
        final entries = await _listDir(normalizedBase, username, password, dir);
        for (final e in entries) {
          if (e.isDir) {
            q.add(e.path.endsWith('/') ? e.path : '${e.path}/');
          } else {
            await AppDatabase.upsertRemoteIndex(
              serverKey: serverKey,
              path: e.path,
              hash: e.md5, // only index when we know hash
              size: e.size,
              etag: e.etag,
            );
            filesIndexed++;
          }
        }
      } catch (e) {
        log.w('indexer: list $dir error: $e');
      }
    }
    return filesIndexed;
  }

  Future<int> _importManifest(String base, String username, String password, String root, String serverKey) async {
    // Manifest directory: <root>/.album_sync/index/
    final manifestDir = root.endsWith('/') ? '${root}.album_sync/index/' : '$root/.album_sync/index/';
    final uri = Uri.parse(base + manifestDir.substring(1));
    final req = http.Request('PROPFIND', uri)
      ..headers['Authorization'] = _basicAuth(username, password)
      ..headers['Depth'] = '1';
    final resp = await _client.send(req).timeout(const Duration(seconds: 45));
    if (resp.statusCode != 207 && resp.statusCode != 200) return 0;
    final xml = await resp.stream.bytesToString();
    final responseRe = RegExp(r'<(?:[a-zA-Z]+:)?response\b[\s\S]*?<\/(?:[a-zA-Z]+:)?response>', multiLine: true);
    final hrefRe = RegExp(r'<(?:[a-zA-Z]+:)?href\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?href>');
    final reqPath = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    final files = <String>[];
    for (final m in responseRe.allMatches(xml)) {
      final block = xml.substring(m.start, m.end);
      final hrefM = hrefRe.firstMatch(block);
      if (hrefM == null) continue;
      var href = hrefM.group(1)!.trim().replaceAll('&amp;', '&');
      Uri? u; try { u = Uri.parse(href); } catch (_) {}
      final path = (u?.hasAuthority ?? false) ? (u!.path) : href;
      final hPath = _safeDecode(path);
      if (_pathsEquivalent(hPath.endsWith('/') ? hPath : '$hPath/', reqPath)) continue; // skip self
      String rel = hPath.startsWith(reqPath) ? hPath.substring(reqPath.length) : hPath.split('/').last;
      if (rel.isEmpty) continue;
      if (rel.endsWith('/')) continue; // only files
      if (rel.toLowerCase().endsWith('.jsonl') || rel.toLowerCase().endsWith('.json')) {
        files.add('$manifestDir$rel');
      }
    }
    int imported = 0;
    for (final rp in files) {
      try {
        final u = Uri.parse(base + rp.substring(1));
        final r = await _client.get(u, headers: {'Authorization': _basicAuth(username, password)}).timeout(const Duration(seconds: 60));
        if (r.statusCode >= 200 && r.statusCode < 300) {
          final lines = r.body.split(RegExp(r'\r?\n')).where((e) => e.trim().isNotEmpty);
          for (final line in lines) {
            try {
              final m = json.decode(line) as Map<String, dynamic>;
              final hash = (m['h'] as String?)?.toLowerCase();
              final path = m['p'] as String?;
              final size = (m['s'] is int) ? m['s'] as int : int.tryParse('${m['s']}');
              final etag = m['e'] as String?;
              if (hash != null && path != null) {
                await AppDatabase.upsertRemoteIndex(serverKey: serverKey, path: path, hash: hash, size: size, etag: etag);
                imported++;
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    return imported;
  }

  Future<List<_Entry>> _listDir(String base, String username, String password, String dirPath) async {
    final uri = Uri.parse(base + dirPath.substring(1));
    final req = http.Request('PROPFIND', uri)
      ..headers['Authorization'] = _basicAuth(username, password)
      ..headers['Depth'] = '1'
      ..headers['Content-Type'] = 'application/xml; charset=utf-8'
      ..body = _propfindBody;
    final resp = await _client.send(req).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 207 && resp.statusCode != 200) {
      return const [];
    }
    final xml = await resp.stream.bytesToString();
    final responseRe = RegExp(r'<(?:[a-zA-Z]+:)?response\b[\s\S]*?<\/(?:[a-zA-Z]+:)?response>', multiLine: true);
    final hrefRe = RegExp(r'<(?:[a-zA-Z]+:)?href\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?href>');
    final contentLenRe = RegExp(r'<(?:[a-zA-Z]+:)?getcontentlength\b[^>]*>(\d+)<\/(?:[a-zA-Z]+:)?getcontentlength>');
    final etagRe = RegExp(r'<(?:[a-zA-Z]+:)?getetag\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?getetag>');
    final checksumRe = RegExp(r'<oc:checksum\b[^>]*>([\s\S]*?)<\/oc:checksum>');
    final reqPath = uri.path;
    final String basePath = reqPath.endsWith('/') ? reqPath : '$reqPath/';
    final list = <_Entry>[];
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
      // determine name and child path
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
      final etag = etagRe.firstMatch(block)?.group(1);
      final checksum = checksumRe.firstMatch(block)?.group(1);
      final md5 = _extractMd5(checksum);
      // detect directory via presence of collection tag
      final isDir = block.contains(RegExp(r'<(?:[a-zA-Z]+:)?collection\b')) || name.isEmpty;
      final full = dirPath.endsWith('/') ? '$dirPath$name' : '$dirPath/$name';
      list.add(_Entry(path: isDir ? '$full/' : full, isDir: isDir, size: size, etag: etag, md5: md5));
    }
    return list;
  }

  String _normalizeBase(String baseUrl) => baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
  String _basicAuth(String u, String p) =>
      'Basic ${base64.encode(utf8.encode('$u:$p'))}';
  String _safeDecode(String s) { try { return Uri.decodeComponent(s); } catch (_) { return s; } }
  bool _pathsEquivalent(String a, String b) { String n(String s) => s.replaceAll(RegExp(r'/+'), '/'); return n(a) == n(b); }
  String? _extractMd5(String? checksum) {
    if (checksum == null) return null;
    final m = RegExp(r'(?:^|\s)MD5:([A-Fa-f0-9]{32})(?:\s|$)').firstMatch(checksum.trim());
    return m != null ? m.group(1)!.toLowerCase() : null;
  }
}

class _Entry {
  final String path;
  final bool isDir;
  final int? size;
  final String? etag;
  final String? md5;
  _Entry({required this.path, required this.isDir, this.size, this.etag, this.md5});
}

const _propfindBody = '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">\n'
    '  <d:prop>\n'
    '    <d:getcontentlength/>\n'
    '    <d:getetag/>\n'
    '    <oc:checksum/>\n'
    '  </d:prop>\n'
    '</d:propfind>';

final remoteIndexerProvider = Provider<RemoteIndexer>((ref) => RemoteIndexer(http.Client()));
