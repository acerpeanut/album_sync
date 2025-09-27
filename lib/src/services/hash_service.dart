import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../core/logger.dart';

class HashService {
  const HashService();

  // Compute MD5 of a file using a streaming approach to avoid memory spikes.
  // Returns lowercase hex digest.
  Future<String> computeMd5(File file, {int chunkSize = 512 * 1024}) async {
    final sw = Stopwatch()..start();
    final total = await file.length();
    final digest = await crypto.md5.bind(file.openRead()).first;
    sw.stop();
    if (kVerboseLog) {
      final mb = (total / (1024 * 1024)).toStringAsFixed(2);
      final secs = (sw.elapsedMilliseconds / 1000).clamp(0.001, 1e9);
      final speed = secs > 0 ? (total / 1024 / 1024 / secs) : 0.0;
      log.i('hash: md5 ${file.path} size=${mb}MB time=${sw.elapsedMilliseconds}ms speed=${speed.toStringAsFixed(2)}MB/s');
    }
    return digest.toString();
  }
}

final hashServiceProvider = Provider<HashService>((ref) => const HashService());
