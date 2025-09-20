import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

class AlbumInfo {
  final String id;
  final String name;
  final int count;

  AlbumInfo({required this.id, required this.name, required this.count});
}

class MediaService {
  const MediaService();

  Future<PermissionState> requestPermission() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state;
  }

  Future<List<AlbumInfo>> listAlbums({bool includeVideos = false}) async {
    final type = includeVideos ? RequestType.common : RequestType.image;
    final paths = await PhotoManager.getAssetPathList(
      type: type,
      onlyAll: false,
    );

    final List<AlbumInfo> albums = [];
    for (final p in paths) {
      final count = await p.assetCountAsync;
      albums.add(AlbumInfo(id: p.id, name: p.name, count: count));
    }
    albums.sort((a, b) => b.count.compareTo(a.count));
    return albums;
  }
}

final mediaServiceProvider = Provider<MediaService>((ref) {
  return const MediaService();
});

