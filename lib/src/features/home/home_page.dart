import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../services/media_service.dart';
import '../upload/upload_page.dart';
import '../settings/settings_page.dart';
import '../drive/drive_browser_page.dart';
import '../../core/config.dart';
import '../../services/settings_service.dart';

final albumsProvider = FutureProvider<List<AlbumInfo>>((ref) async {
  final media = ref.read(mediaServiceProvider);
  // Ensure permission granted
  final state = await media.requestPermission();
  if (!state.isAuth) {
    throw Exception('未获得访问照片权限');
  }
  final includeVideos = ref
      .watch(settingsControllerProvider)
      .maybeWhen(data: (v) => v.includeVideos, orElse: () => false);
  return media.listAlbums(includeVideos: includeVideos);
});

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _autoStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_autoStarted && kAutoUpload) {
      _autoStarted = true;
      Future.microtask(() {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const UploadPage()),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final albumsAsync = ref.watch(albumsProvider);
    final settingsAsync = ref.watch(settingsControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('相册同步'),
        actions: [
          IconButton(
            tooltip: '网盘浏览',
            onPressed: () async {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DriveBrowserPage()),
              );
            },
            icon: const Icon(Icons.cloud_outlined),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () async {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: '退出登录',
            onPressed: () => ref.read(settingsControllerProvider.notifier).signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(albumsProvider);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        },
        child: albumsAsync.when(
          data: (albums) {
            if (albums.isEmpty) {
              return const Center(child: Text('没有可用相册或相册为空'));
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: albums.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final a = albums[i];
                return ListTile(
                  leading: const Icon(Icons.photo_album_outlined),
                  title: Text(a.name),
                  subtitle: Text('共 ${a.count} 项'),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('即将支持上传相册：${a.name}')),
                    );
                  },
                );
              },
            );
          },
          loading: () => ListView(
            children: [
              SizedBox(height: 200),
              Center(child: CircularProgressIndicator()),
            ],
          ),
          error: (e, st) {
            String hint = '请在系统设置中授予相册访问权限';
            if (e.toString().contains('未获得')) {
              hint = '未获得照片权限，点击重试或前往设置授权';
            }
            return ListView(
              children: [
                const SizedBox(height: 120),
                Icon(Icons.photo_outlined, size: 48, color: Colors.grey.shade600),
                const SizedBox(height: 16),
                Center(child: Text('$e')),
                const SizedBox(height: 8),
                Center(child: Text(hint, style: const TextStyle(color: Colors.grey))),
                const SizedBox(height: 16),
                Center(
                  child: FilledButton(
                    onPressed: () => ref.invalidate(albumsProvider),
                    child: const Text('重试'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: settingsAsync.when(
        data: (s) => Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            '服务器: ${s.baseUrl ?? '-'}  根目录: ${s.baseRemoteDir ?? '/Albums'}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        loading: () => const SizedBox.shrink(),
        error: (e, st) => const SizedBox.shrink(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const UploadPage()),
          );
        },
        icon: const Icon(Icons.cloud_upload_outlined),
        label: const Text('开始上传'),
      ),
    );
  }
}
