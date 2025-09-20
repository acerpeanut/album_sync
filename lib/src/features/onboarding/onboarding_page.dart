import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/settings_service.dart';
import '../../services/webdav_service.dart';
import '../../core/config.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _formKey = GlobalKey<FormState>();
  final _urlCtrl = TextEditingController(
      text: kDefaultBaseUrl);
  final _userCtrl = TextEditingController(text: kDefaultUsername);
  final _passCtrl = TextEditingController(text: kDefaultPassword);
  final _dirCtrl = TextEditingController(text: '/Albums');
  bool _wifiOnly = true;
  bool _includeVideos = false;
  int _parallel = 2;
  bool _testing = false;
  bool _incrementalOnly = false;
  int _recentDays = 7;
  int _recentPages = 0;
  bool _parallelScanUpload = true;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // 如果通过 dart-define 传入了默认凭据且要求自动设置，则尝试自动验证与保存
    if (kAutoSetup &&
        _urlCtrl.text.isNotEmpty &&
        _userCtrl.text.isNotEmpty &&
        _passCtrl.text.isNotEmpty) {
      Future.microtask(_validateAndSave);
    }
  }

  Future<void> _validateAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _testing = true);
    final ok = await ref.read(webDavServiceProvider).validateCredentials(
          baseUrl: _urlCtrl.text.trim(),
          username: _userCtrl.text.trim(),
          password: _passCtrl.text,
        );
    if (!mounted) return;
    setState(() => _testing = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('连接失败，请检查地址或凭据')),
      );
      return;
    }

    await ref.read(settingsControllerProvider.notifier).saveAndReload(
          baseUrl: _urlCtrl.text.trim(),
          username: _userCtrl.text.trim(),
          password: _passCtrl.text,
          baseRemoteDir: _dirCtrl.text.trim().isEmpty ? '/Albums' : _dirCtrl.text.trim(),
          wifiOnly: _wifiOnly,
          includeVideos: _includeVideos,
          maxParallelUploads: _parallel,
          incrementalOnly: _incrementalOnly,
          recentDays: _recentDays,
          recentPages: _recentPages,
          parallelScanUpload: _parallelScanUpload,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置 WebDAV')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: '例如：https://example.com/dav/',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? '请输入服务器地址'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _userCtrl,
                decoration: const InputDecoration(labelText: '用户名'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? '请输入用户名'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passCtrl,
                decoration: const InputDecoration(labelText: '密码'),
                obscureText: true,
                validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _dirCtrl,
                decoration: const InputDecoration(
                  labelText: '远端根目录',
                  hintText: '/Albums',
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('仅 Wi‑Fi 上传'),
                value: _wifiOnly,
                onChanged: (v) => setState(() => _wifiOnly = v),
              ),
              SwitchListTile(
                title: const Text('包含视频（实验性）'),
                value: _includeVideos,
                onChanged: (v) => setState(() => _includeVideos = v),
              ),
              Row(
                children: [
                  const Text('并发上传数：'),
                  DropdownButton<int>(
                    value: _parallel,
                    items: const [2, 3, 4]
                        .map((e) => DropdownMenuItem(value: e, child: Text('$e')))
                        .toList(),
                    onChanged: (v) => setState(() => _parallel = v ?? 2),
                  )
                ],
              ),
              const Divider(),
              SwitchListTile(
                title: const Text('仅新照片扫描（增量）'),
                subtitle: const Text('按最后成功时间 + 最近N天/N页 限定'),
                value: _incrementalOnly,
                onChanged: (v) => setState(() => _incrementalOnly = v),
              ),
              if (_incrementalOnly) ...[
                Row(children: [
                  const Text('最近天数：'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      initialValue: _recentDays.toString(),
                      keyboardType: TextInputType.number,
                      onChanged: (v) => _recentDays = int.tryParse(v) ?? 7,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text('最近页数：'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      initialValue: _recentPages.toString(),
                      keyboardType: TextInputType.number,
                      onChanged: (v) => _recentPages = int.tryParse(v) ?? 0,
                    ),
                  ),
                ]),
              ],
              SwitchListTile(
                title: const Text('扫描与上传并行（更快）'),
                value: _parallelScanUpload,
                onChanged: (v) => setState(() => _parallelScanUpload = v),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _testing ? null : _validateAndSave,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(_testing ? '正在验证…' : '验证并保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
