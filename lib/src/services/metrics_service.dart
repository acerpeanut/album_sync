import 'package:flutter_riverpod/flutter_riverpod.dart';

class MetricsService {
  final Map<String, int> _skip = <String, int>{};

  void incSkip(String reason) {
    final r = reason.toUpperCase();
    _skip[r] = (_skip[r] ?? 0) + 1;
  }

  Map<String, int> skipSnapshot() => Map<String, int>.from(_skip);
  void reset() => _skip.clear();
}

final metricsServiceProvider = Provider<MetricsService>((ref) => MetricsService());

