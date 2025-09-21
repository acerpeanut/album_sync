import 'dart:async';

typedef ProgressCallback = FutureOr<void> Function(int bytesSent);

class ProgressByteStream extends Stream<List<int>> {
  ProgressByteStream(this._source, this._onProgress);

  final Stream<List<int>> _source;
  final ProgressCallback _onProgress;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _source.listen((chunk) {
      _onProgress(chunk.length);
      if (onData != null) onData(chunk);
    }, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}
