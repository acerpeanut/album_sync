import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kBaseUrl = 'baseUrl';
const _kUsername = 'username';
const _kBaseRemoteDir = 'baseRemoteDir';
const _kWifiOnly = 'wifiOnly';
const _kIncludeVideos = 'includeVideos';
const _kMaxParallel = 'maxParallel';
const _kPasswordKey = 'password';
const _kIncrementalOnly = 'incrementalOnly';
const _kRecentDays = 'recentDays';
const _kRecentPages = 'recentPages';
const _kParallelScanUpload = 'parallelScanUpload';
const _kLastSuccessTs = 'lastSuccessTs';

class AppSettings {
  final String? baseUrl;
  final String? username;
  final String? baseRemoteDir;
  final bool wifiOnly;
  final bool includeVideos;
  final int maxParallelUploads;
  final bool incrementalOnly;
  final int recentDays;
  final int recentPages;
  final bool parallelScanUpload;

  const AppSettings({
    required this.baseUrl,
    required this.username,
    required this.baseRemoteDir,
    required this.wifiOnly,
    required this.includeVideos,
    required this.maxParallelUploads,
    required this.incrementalOnly,
    required this.recentDays,
    required this.recentPages,
    required this.parallelScanUpload,
  });

  bool get isConfigured =>
      (baseUrl != null && baseUrl!.isNotEmpty) &&
      (username != null && username!.isNotEmpty);

  AppSettings copyWith({
    String? baseUrl,
    String? username,
    String? baseRemoteDir,
    bool? wifiOnly,
    bool? includeVideos,
    int? maxParallelUploads,
    bool? incrementalOnly,
    int? recentDays,
    int? recentPages,
    bool? parallelScanUpload,
  }) {
    return AppSettings(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      baseRemoteDir: baseRemoteDir ?? this.baseRemoteDir,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      includeVideos: includeVideos ?? this.includeVideos,
      maxParallelUploads: maxParallelUploads ?? this.maxParallelUploads,
      incrementalOnly: incrementalOnly ?? this.incrementalOnly,
      recentDays: recentDays ?? this.recentDays,
      recentPages: recentPages ?? this.recentPages,
      parallelScanUpload: parallelScanUpload ?? this.parallelScanUpload,
    );
  }
}

class SettingsService {
  SettingsService({
    FlutterSecureStorage? secureStorage,
  }) : _secure = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_kBaseUrl);
    final username = prefs.getString(_kUsername);
    final baseRemoteDir = prefs.getString(_kBaseRemoteDir) ?? '/Albums';
    final wifiOnly = prefs.getBool(_kWifiOnly) ?? true;
    final includeVideos = prefs.getBool(_kIncludeVideos) ?? false;
    final maxParallel = prefs.getInt(_kMaxParallel) ?? 2;
    final incrementalOnly = prefs.getBool(_kIncrementalOnly) ?? false;
    final recentDays = prefs.getInt(_kRecentDays) ?? 7;
    final recentPages = prefs.getInt(_kRecentPages) ?? 0;
    final parallelScanUpload = prefs.getBool(_kParallelScanUpload) ?? true;
    return AppSettings(
      baseUrl: baseUrl,
      username: username,
      baseRemoteDir: baseRemoteDir,
      wifiOnly: wifiOnly,
      includeVideos: includeVideos,
      maxParallelUploads: maxParallel,
      incrementalOnly: incrementalOnly,
      recentDays: recentDays,
      recentPages: recentPages,
      parallelScanUpload: parallelScanUpload,
    );
  }

  Future<void> save({
    required String baseUrl,
    required String username,
    required String password,
    String baseRemoteDir = '/Albums',
    bool wifiOnly = true,
    bool includeVideos = false,
    int maxParallelUploads = 2,
    bool incrementalOnly = false,
    int recentDays = 7,
    int recentPages = 0,
    bool parallelScanUpload = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, baseUrl);
    await prefs.setString(_kUsername, username);
    await prefs.setString(_kBaseRemoteDir, baseRemoteDir);
    await prefs.setBool(_kWifiOnly, wifiOnly);
    await prefs.setBool(_kIncludeVideos, includeVideos);
    await prefs.setInt(_kMaxParallel, maxParallelUploads);
    await prefs.setBool(_kIncrementalOnly, incrementalOnly);
    await prefs.setInt(_kRecentDays, recentDays);
    await prefs.setInt(_kRecentPages, recentPages);
    await prefs.setBool(_kParallelScanUpload, parallelScanUpload);
    await _secure.write(key: _kPasswordKey, value: password);
  }

  Future<String?> loadPassword() async {
    return _secure.read(key: _kPasswordKey);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kBaseUrl);
    await prefs.remove(_kUsername);
    await prefs.remove(_kBaseRemoteDir);
    await prefs.remove(_kWifiOnly);
    await prefs.remove(_kIncludeVideos);
    await prefs.remove(_kMaxParallel);
    await prefs.remove(_kIncrementalOnly);
    await prefs.remove(_kRecentDays);
    await prefs.remove(_kRecentPages);
    await prefs.remove(_kParallelScanUpload);
    await _secure.delete(key: _kPasswordKey);
  }

  Future<int?> loadLastSuccessTs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kLastSuccessTs);
  }

  Future<void> markLastSuccessNow() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastSuccessTs, DateTime.now().millisecondsSinceEpoch);
  }
}

class SettingsController extends StateNotifier<AsyncValue<AppSettings>> {
  SettingsController(this._service) : super(const AsyncValue.loading()) {
    _load();
  }

  final SettingsService _service;

  Future<void> _load() async {
    try {
      final settings = await _service.load();
      state = AsyncValue.data(settings);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> saveAndReload({
    required String baseUrl,
    required String username,
    required String password,
    required String baseRemoteDir,
    required bool wifiOnly,
    required bool includeVideos,
    required int maxParallelUploads,
    bool incrementalOnly = false,
    int recentDays = 7,
    int recentPages = 0,
    bool parallelScanUpload = true,
  }) async {
    state = const AsyncValue.loading();
    await _service.save(
      baseUrl: baseUrl,
      username: username,
      password: password,
      baseRemoteDir: baseRemoteDir,
      wifiOnly: wifiOnly,
      includeVideos: includeVideos,
      maxParallelUploads: maxParallelUploads,
      incrementalOnly: incrementalOnly,
      recentDays: recentDays,
      recentPages: recentPages,
      parallelScanUpload: parallelScanUpload,
    );
    await _load();
  }

  Future<void> signOut() async {
    state = const AsyncValue.loading();
    await _service.clear();
    await _load();
  }
}

final settingsServiceProvider = Provider<SettingsService>((ref) {
  return SettingsService();
});

final settingsControllerProvider =
    StateNotifierProvider<SettingsController, AsyncValue<AppSettings>>((ref) {
  final service = ref.watch(settingsServiceProvider);
  return SettingsController(service);
});
