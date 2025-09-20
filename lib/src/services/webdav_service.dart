import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

String _normalizeBaseUrl(String baseUrl) {
  var url = baseUrl.trim();
  if (!url.endsWith('/')) url = '$url/';
  return url;
}

class WebDavService {
  const WebDavService();

  Future<bool> validateCredentials({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final url = Uri.parse(_normalizeBaseUrl(baseUrl));

    final request = http.Request('PROPFIND', url);
    final auth = base64Encode(utf8.encode('$username:$password'));
    request.headers.addAll({
      'Authorization': 'Basic $auth',
      'Depth': '0',
      'Content-Type': 'text/xml; charset="utf-8"',
      'Accept': 'text/xml',
    });
    request.body =
        '<?xml version="1.0" encoding="utf-8" ?>\n<propfind xmlns="DAV:"><propname/></propfind>';

    try {
      final response = await http.Response.fromStream(await request.send());
      // WebDAV success for PROPFIND is typically 207 Multi-Status.
      return response.statusCode == 207 || response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<WebDavEntry>> listDirectory({
    required String baseUrl,
    required String username,
    required String password,
    required String remotePath,
  }) async {
    final base = _normalizeBaseUrl(baseUrl);
    final path = _normalizeRemotePath(remotePath);
    final url = Uri.parse(base + path.substring(1));

    final req = http.Request('PROPFIND', url);
    final auth = base64Encode(utf8.encode('$username:$password'));
    req.headers.addAll({
      'Authorization': 'Basic $auth',
      'Depth': '1',
      'Content-Type': 'text/xml; charset="utf-8"',
      'Accept': 'text/xml',
    });
    req.body =
        '<?xml version="1.0" encoding="utf-8" ?>\n'
        '<propfind xmlns="DAV:">\n'
        '  <prop>\n'
        '    <displayname/>\n'
        '    <getcontentlength/>\n'
        '    <getlastmodified/>\n'
        '    <resourcetype/>\n'
        '    <getcontenttype/>\n'
        '  </prop>\n'
        '</propfind>';
    final resp = await http.Response.fromStream(await req.send());
    if (resp.statusCode != 207 && resp.statusCode != 200) {
      throw HttpException('PROPFIND ${resp.statusCode}');
    }
    return _parsePropfindMultiStatus(
      xml: resp.body,
      requestPath: url.path.endsWith('/') ? url.path : '${url.path}/',
      remoteBasePath: _normalizeRemotePath(path),
    );
  }

  Future<void> mkcol({
    required String baseUrl,
    required String username,
    required String password,
    required String remoteDirPath,
  }) async {
    final base = _normalizeBaseUrl(baseUrl);
    final path = _normalizeRemotePath(remoteDirPath);
    final url = Uri.parse(base + path.substring(1));
    final req = http.Request('MKCOL', url)
      ..headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    final s = await req.send();
    // 201 Created / 200 OK / 405 Already exists
    if (s.statusCode >= 200 && s.statusCode < 300) return;
    if (s.statusCode == 405) return;
    throw HttpException('MKCOL ${s.statusCode}');
  }

  Future<void> remove({
    required String baseUrl,
    required String username,
    required String password,
    required String remotePath,
  }) async {
    final base = _normalizeBaseUrl(baseUrl);
    final path = _normalizeRemotePath(remotePath);
    final url = Uri.parse(base + path.substring(1));
    final req = http.Request('DELETE', url)
      ..headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    final s = await req.send();
    if (s.statusCode >= 200 && s.statusCode < 300) return;
    throw HttpException('DELETE ${s.statusCode}');
  }

  Future<void> renameOrMove({
    required String baseUrl,
    required String username,
    required String password,
    required String srcRemotePath,
    required String destRemotePath,
    bool overwrite = true,
  }) async {
    final base = _normalizeBaseUrl(baseUrl);
    final src = _normalizeRemotePath(srcRemotePath);
    final dst = _normalizeRemotePath(destRemotePath);
    final srcUrl = Uri.parse(base + src.substring(1));
    final dstUrl = Uri.parse(base + dst.substring(1));
    final req = http.Request('MOVE', srcUrl)
      ..headers.addAll({
        'Authorization': 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        'Destination': dstUrl.toString(),
        'Overwrite': overwrite ? 'T' : 'F',
      });
    final s = await req.send();
    if (s.statusCode >= 200 && s.statusCode < 300) return;
    throw HttpException('MOVE ${s.statusCode}');
  }

  String _normalizeRemotePath(String path) {
    if (path.isEmpty) return '/';
    var p = path.trim();
    if (!p.startsWith('/')) p = '/$p';
    // For directories, keeping trailing slash helps some servers
    if (!p.endsWith('/')) return p; // may be a file path
    // collapse multiple slashes
    p = p.replaceAll(RegExp(r'/+'), '/');
    return p;
  }

  List<WebDavEntry> _parsePropfindMultiStatus({
    required String xml,
    required String requestPath,
    required String remoteBasePath,
  }) {
    final items = <WebDavEntry>[];
    final responseRe = RegExp(r'<(?:[a-zA-Z]+:)?response\b[\s\S]*?<\/(?:[a-zA-Z]+:)?response>', multiLine: true);
    final hrefRe = RegExp(r'<(?:[a-zA-Z]+:)?href\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?href>');
    final displayNameRe = RegExp(r'<(?:[a-zA-Z]+:)?displayname\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?displayname>');
    final contentLenRe = RegExp(r'<(?:[a-zA-Z]+:)?getcontentlength\b[^>]*>(\d+)<\/(?:[a-zA-Z]+:)?getcontentlength>');
    final lastModRe = RegExp(r'<(?:[a-zA-Z]+:)?getlastmodified\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?getlastmodified>');
    final collectionRe = RegExp(r'<(?:[a-zA-Z]+:)?collection\b\s*\/?>');
    final contentTypeRe = RegExp(r'<(?:[a-zA-Z]+:)?getcontenttype\b[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?getcontenttype>');

    for (final m in responseRe.allMatches(xml)) {
      final block = xml.substring(m.start, m.end);
      final hrefM = hrefRe.firstMatch(block);
      if (hrefM == null) continue;
      var href = hrefM.group(1)!.trim();
      href = href.replaceAll('&amp;', '&');
      // Some servers return absolute URLs or relative paths
      Uri? u;
      try {
        u = Uri.parse(href);
      } catch (_) {}
      final hrefPath = (u?.hasAuthority ?? false) ? (u!.path) : href;
      // Normalize; tolerate invalid percent sequences in names
      final hPath = _safeDecode(hrefPath);
      final reqPath = requestPath.endsWith('/') ? requestPath : '$requestPath/';
      final hPathNorm = hPath.endsWith('/') ? hPath : '$hPath/';
      // Skip self (the directory itself)
      if (_pathsEquivalent(hPathNorm, reqPath)) {
        continue;
      }

      // Extract name relative to requestPath
      String rel;
      if (hPath.startsWith(reqPath)) {
        rel = hPath.substring(reqPath.length);
      } else {
        // best-effort: take last segment
        rel = hPath.split('/').where((e) => e.isNotEmpty).isNotEmpty
            ? hPath.split('/').where((e) => e.isNotEmpty).last
            : hPath;
      }
      if (rel.startsWith('/')) rel = rel.substring(1);
      if (rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);
      final name = _safeDecode(rel);

      final isDir = collectionRe.hasMatch(block) || hPath.endsWith('/');
      final lenStr = contentLenRe.firstMatch(block)?.group(1);
      final size = lenStr != null ? int.tryParse(lenStr) : null;
      final lmStr = lastModRe.firstMatch(block)?.group(1)?.trim();
      DateTime? modified;
      if (lmStr != null && lmStr.isNotEmpty) {
        try {
          modified = HttpDate.parse(lmStr);
        } catch (_) {
          try { modified = DateTime.tryParse(lmStr); } catch (_) {}
        }
      }
      final ct = contentTypeRe.firstMatch(block)?.group(1)?.trim();

      // Build remote path for item (relative to baseUrl root)
      // We don't know server prefix, so reconstruct using requestPath + rel
      // Build remote path relative to caller-provided remoteBasePath (without server prefix)
      final rb = remoteBasePath.endsWith('/') ? remoteBasePath : '$remoteBasePath/';
      final itemPath = _ensureLeadingSlash(rb + rel + (isDir ? '/' : ''));

      items.add(WebDavEntry(
        name: name,
        remotePath: itemPath,
        isDirectory: isDir,
        size: size,
        lastModified: modified,
        contentType: ct,
      ));
    }

    // sort: directories first, then by name
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  bool _pathsEquivalent(String a, String b) {
    String n(String s) => s.replaceAll(RegExp(r'/+'), '/');
    return n(a) == n(b);
  }

  String _ensureLeadingSlash(String p) => p.startsWith('/') ? p : '/$p';

  String _safeDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }
}

final webDavServiceProvider = Provider<WebDavService>((ref) {
  return const WebDavService();
});

class WebDavEntry {
  final String name;
  final String remotePath; // absolute path on server (starting with '/')
  final bool isDirectory;
  final int? size;
  final DateTime? lastModified;
  final String? contentType;

  const WebDavEntry({
    required this.name,
    required this.remotePath,
    required this.isDirectory,
    this.size,
    this.lastModified,
    this.contentType,
  });
}
