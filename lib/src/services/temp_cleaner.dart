import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/logger.dart';

class TempUsage {
  final int tmpBytes;
  final int files;
  const TempUsage({required this.tmpBytes, required this.files});
}

class CleanReport {
  final int deletedFiles;
  final int freedBytes;
  const CleanReport({required this.deletedFiles, required this.freedBytes});
}

class TempCleaner {
  const TempCleaner();

  Future<String> _tmpPath() async => (await getTemporaryDirectory()).path;

  bool _isUnderTmp(String path, String tmpRoot) {
    try {
      final normPath = p.normalize(path);
      final normRoot = p.normalize(tmpRoot);
      return p.isWithin(normRoot, normPath) || p.equals(normPath, normRoot) || normPath.startsWith(normRoot);
    } catch (_) {
      return path.startsWith(tmpRoot);
    }
  }

  Future<TempUsage> measureUsage() async {
    final tmp = await _tmpPath();
    int total = 0;
    int files = 0;
    try {
      final dir = Directory(tmp);
      if (await dir.exists()) {
        await for (final ent in dir.list(recursive: true, followLinks: false)) {
          if (ent is File) {
            files++;
            total += await _safeLen(ent);
          }
        }
      }
    } catch (_) {}
    return TempUsage(tmpBytes: total, files: files);
  }

  Future<CleanReport> cleanTemp({Duration olderThan = const Duration(hours: 24)}) async {
    final tmp = await _tmpPath();
    int deleted = 0;
    int freed = 0;
    final deadline = DateTime.now().subtract(olderThan);
    try {
      final dir = Directory(tmp);
      if (!await dir.exists()) return const CleanReport(deletedFiles: 0, freedBytes: 0);
      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        if (ent is File) {
          try {
            final stat = await ent.stat();
            if (stat.modified.isBefore(deadline)) {
              final len = stat.size;
              await ent.delete();
              deleted++;
              freed += len;
            }
          } catch (_) {/* ignore */}
        }
      }
      // Clean empty directories best-effort
      await _removeEmptyDirectories(dir);
    } catch (e) {
      if (kDebugMode) log.w('temp clean error: $e');
    }
    return CleanReport(deletedFiles: deleted, freedBytes: freed);
  }

  Future<void> _removeEmptyDirectories(Directory root) async {
    try {
      final dirs = <Directory>[];
      await for (final ent in root.list(recursive: true, followLinks: false)) {
        if (ent is Directory) dirs.add(ent);
      }
      dirs.sort((a, b) => b.path.length.compareTo(a.path.length)); // deepest first
      for (final d in dirs) {
        try {
          if ((await d.list(followLinks: false).isEmpty)) {
            await d.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> maybeDeleteTempFile(String filePath) async {
    try {
      final tmp = await _tmpPath();
      if (_isUnderTmp(filePath, tmp)) {
        final f = File(filePath);
        if (await f.exists()) {
          await f.delete();
          if (kDebugMode) log.i('temp: deleted $filePath');
        }
      }
    } catch (_) {}
  }

  Future<int> _safeLen(File f) async { try { return await f.length(); } catch (_) { return 0; } }
}

final tempCleanerProvider = Provider<TempCleaner>((ref) => const TempCleaner());

