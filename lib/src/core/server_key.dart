String normalizeBaseUrl(String baseUrl) {
  var u = baseUrl.trim();
  if (!u.endsWith('/')) u = '$u/';
  try {
    final uri = Uri.parse(u);
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final port = (uri.hasPort) ? ':${uri.port}' : (uri.scheme == 'https' ? '' : '');
    final path = uri.path;
    return '$scheme://$host$port$path';
  } catch (_) {
    return u;
  }
}

String buildServerKey(String baseUrl, String username) {
  final n = normalizeBaseUrl(baseUrl);
  // Simple stable key without crypto dep: lowercase concatenation
  return '$n|$username';
}

