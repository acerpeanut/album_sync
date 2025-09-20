import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/features/home/home_page.dart';
import 'src/features/onboarding/onboarding_page.dart';
import 'src/services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: AlbumSyncApp()));
}

class AlbumSyncApp extends ConsumerWidget {
  const AlbumSyncApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsControllerProvider);
    return MaterialApp(
      title: 'Album Sync',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: settingsAsync.when(
        data: (settings) => settings.isConfigured
            ? const HomePage()
            : const OnboardingPage(),
        loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        error: (e, st) => Scaffold(
          body: Center(child: Text('初始化失败: $e')),
        ),
      ),
    );
  }
}
