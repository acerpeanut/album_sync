String sanitizeSegment(String input) {
  // Replace slashes and control characters; trim spaces; limit length.
  var s = input
      .replaceAll('/', '_')
      .replaceAll('\\', '_')
      .replaceAll(RegExp(r'[\n\r\t]'), ' ')
      .trim();
  if (s.isEmpty) return 'untitled';
  if (s.length > 120) s = s.substring(0, 120);
  return s;
}

String joinUrlSegments(List<String> segments) {
  final encoded = segments
      .map((e) => e)
      .map(Uri.encodeComponent)
      .join('/');
  return '/$encoded';
}

