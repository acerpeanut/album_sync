import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

class DriveWebViewPage extends StatefulWidget {
  final String title;
  final String url; // absolute
  final String? username;
  final String? password;

  const DriveWebViewPage({
    super.key,
    required this.title,
    required this.url,
    this.username,
    this.password,
  });

  @override
  State<DriveWebViewPage> createState() => _DriveWebViewPageState();
}

class _DriveWebViewPageState extends State<DriveWebViewPage> {
  late final WebViewController _controller;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    final headers = <String, String>{};
    if ((widget.username?.isNotEmpty ?? false)) {
      final auth = base64Encode(utf8.encode('${widget.username}:${widget.password ?? ''}'));
      headers['Authorization'] = 'Basic $auth';
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // Always allow in-view navigation; headers only applied to top-level loads.
            return NavigationDecision.navigate;
          },
          onUrlChange: (c) {},
          onPageStarted: (_) => setState(() => _progress = 10),
          onProgress: (p) => setState(() => _progress = p),
          onPageFinished: (_) => setState(() => _progress = 100),
        ),
      )
      ..loadRequest(Uri.parse(widget.url), headers: headers);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_progress < 100)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(value: _progress == 0 ? null : _progress / 100),
              ),
            ),
          IconButton(
            tooltip: '在浏览器打开',
            onPressed: () async {
              // ignore: deprecated_member_use
              await launchUrlString(widget.url, mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.open_in_new),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => _controller.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}

