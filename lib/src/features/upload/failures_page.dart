import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import 'upload_controller.dart';

final failuresProvider = FutureProvider<List<UploadTask>>((ref) async {
  return AppDatabase.listFailed(limit: 200);
});

class FailuresPage extends ConsumerWidget {
  const FailuresPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failed = ref.watch(failuresProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('失败任务')),
      body: failed.when(
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('暂无失败任务'));
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final t = list[i];
              return ListTile(
                dense: true,
                title: Text(t.remotePath, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(t.lastError ?? '未知错误'),
                trailing: Wrap(spacing: 8, children: [
                  OutlinedButton(
                    onPressed: () async {
                      await ref.read(uploadControllerProvider.notifier).requeueOne(t.id!);
                      ref.invalidate(failuresProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已重试该任务')));
                      }
                    },
                    child: const Text('重试'),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      await ref.read(uploadControllerProvider.notifier).deleteOne(t.id!);
                      ref.invalidate(failuresProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除该任务')));
                      }
                    },
                    child: const Text('删除'),
                  ),
                ]),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('加载失败: $e')),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(8.0),
        child: FilledButton.icon(
          onPressed: () async {
            await ref.read(uploadControllerProvider.notifier).startQueuedUploads();
          },
          icon: const Icon(Icons.play_arrow),
          label: const Text('仅上传当前队列'),
        ),
      ),
    );
  }
}

