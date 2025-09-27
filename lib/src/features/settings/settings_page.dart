import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/settings_service.dart';
import '../../services/webdav_service.dart';
import '../diagnostics/diagnostics_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _dirCtrl = TextEditingController();
  bool _wifiOnly = true;
  bool _includeVideos = false;
  int _parallel = 2;
  bool _testing = false;
  bool _incrementalOnly = false;
  int _recentDays = 7;
  int _recentPages = 0;
  bool _parallelScanUpload = true;
  bool _enableContentHash = true;
  bool _hashWifiOnly = true;
  bool _bootstrapRemoteIndex = true;
  bool _allowReorganizeMove = false;
  bool _hashDuringScan = false;
  int _indexerConcurrency = 4;
  int _indexerTimeoutSec = 60;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsControllerProvider).value;
    _urlCtrl.text = s?.baseUrl ?? '';
    _userCtrl.text = s?.username ?? '';
    _dirCtrl.text = s?.baseRemoteDir ?? '/Albums';
    _wifiOnly = s?.wifiOnly ?? true;
    _includeVideos = s?.includeVideos ?? false;
    _parallel = s?.maxParallelUploads ?? 2;
    _incrementalOnly = s?.incrementalOnly ?? false;
    _recentDays = s?.recentDays ?? 7;
    _recentPages = s?.recentPages ?? 0;
    _parallelScanUpload = s?.parallelScanUpload ?? true;
    _enableContentHash = s?.enableContentHash ?? true;
    _hashWifiOnly = s?.hashWifiOnly ?? true;
    _bootstrapRemoteIndex = s?.bootstrapRemoteIndex ?? true;
    _allowReorganizeMove = s?.allowReorganizeMove ?? false;
    _hashDuringScan = s?.hashDuringScan ?? false;
    _indexerConcurrency = s?.indexerConcurrency ?? 4;
    _indexerTimeoutSec = s?.indexerTimeoutSec ?? 60;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _validateAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _testing = true);
    final password = _passCtrl.text.isEmpty
        ? await ref.read(settingsServiceProvider).loadPassword() ?? ''
        : _passCtrl.text;
    final ok = await ref.read(webDavServiceProvider).validateCredentials(
          baseUrl: _urlCtrl.text.trim(),
          username: _userCtrl.text.trim(),
          password: password,
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
          password: password,
          baseRemoteDir: _dirCtrl.text.trim().isEmpty ? '/Albums' : _dirCtrl.text.trim(),
          wifiOnly: _wifiOnly,
          includeVideos: _includeVideos,
          maxParallelUploads: _parallel,
          incrementalOnly: _incrementalOnly,
          recentDays: _recentDays,
          recentPages: _recentPages,
          parallelScanUpload: _parallelScanUpload,
          enableContentHash: _enableContentHash,
          hashWifiOnly: _hashWifiOnly,
          bootstrapRemoteIndex: _bootstrapRemoteIndex,
          allowReorganizeMove: _allowReorganizeMove,
          hashDuringScan: _hashDuringScan,
          indexerConcurrency: _indexerConcurrency,
          indexerTimeoutSec: _indexerTimeoutSec,
        );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _urlCtrl,
                decoration: const InputDecoration(labelText: '服务器地址'),
                validator: (v) => (v == null || v.trim().isEmpty) ? '请输入服务器地址' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _userCtrl,
                decoration: const InputDecoration(labelText: '用户名'),
                validator: (v) => (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passCtrl,
                decoration: const InputDecoration(labelText: '密码（留空则不修改）'),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _dirCtrl,
                decoration: const InputDecoration(labelText: '远端根目录'),
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
              const Divider(),
              const Text('去重与重装', style: TextStyle(fontWeight: FontWeight.bold)),
              SwitchListTile(
                title: const Text('启用内容哈希去重'),
                subtitle: const Text('计算MD5用于远端去重（推荐，仅Wi‑Fi时进行）'),
                value: _enableContentHash,
                onChanged: (v) => setState(() => _enableContentHash = v),
              ),
              SwitchListTile(
                title: const Text('仅 Wi‑Fi 计算哈希'),
                value: _hashWifiOnly,
                onChanged: (v) => setState(() => _hashWifiOnly = v),
              ),
              SwitchListTile(
                title: const Text('启动时引导远端索引'),
                value: _bootstrapRemoteIndex,
                onChanged: (v) => setState(() => _bootstrapRemoteIndex = v),
              ),
              SwitchListTile(
                title: const Text('扫描阶段哈希去重（实验）'),
                subtitle: const Text('扫描时若命中远端索引则不入队，可能影响速度'),
                value: _hashDuringScan,
                onChanged: (v) => setState(() => _hashDuringScan = v),
              ),
              SwitchListTile(
                title: const Text('允许按新规则重组（MOVE）'),
                subtitle: const Text('命中哈希但路径不同，则尝试服务器MOVE而非重传'),
                value: _allowReorganizeMove,
                onChanged: (v) => setState(() => _allowReorganizeMove = v),
              ),
              Row(children: [
                const Text('索引并发：'),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _indexerConcurrency,
                  items: const [2,3,4,5,6]
                      .map((e) => DropdownMenuItem(value: e, child: Text('$e')))
                      .toList(),
                  onChanged: (v) => setState(() => _indexerConcurrency = v ?? 4),
                ),
                const SizedBox(width: 16),
                const Text('超时(秒)：'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: _indexerTimeoutSec.toString(),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _indexerTimeoutSec = int.tryParse(v) ?? 60,
                  ),
                ),
              ]),
              Row(children: [
                const Text('并发上传数：'),
                DropdownButton<int>(
                  value: _parallel,
                  items: const [2, 3, 4]
                      .map((e) => DropdownMenuItem(value: e, child: Text('$e')))
                      .toList(),
                  onChanged: (v) => setState(() => _parallel = v ?? 2),
                )
              ]),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _testing ? null : _validateAndSave,
                icon: _testing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                label: Text(_testing ? '正在验证…' : '保存'),
              ),
              const SizedBox(height: 24),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.science_outlined),
                title: const Text('诊断与日志'),
                subtitle: const Text('查看统计、失败列表，执行修复操作'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DiagnosticsPage()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
