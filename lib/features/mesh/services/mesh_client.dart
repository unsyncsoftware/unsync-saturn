import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/constants/app_constants.dart';

class MeshFetchResult {
  const MeshFetchResult({
    required this.success,
    required this.status,
    required this.mime,
    this.bytes,
    this.error,
  });

  final bool success;
  final int status;
  final String mime;
  final Uint8List? bytes;
  final String? error;
}

class MeshClient {
  MeshClient() : saturnPeerId = 'saturn-${_randomHex(16)}';

  static const _requestTimeout = Duration(seconds: 15);
  static const _keepaliveInterval = Duration(seconds: 20);
  static const _reconnectDelay = Duration(seconds: 5);
  static final Random _random = Random.secure();

  final String saturnPeerId;

  WebSocketChannel? _channel;
  Completer<void>? _connecting;
  Timer? _keepaliveTimer;
  Timer? _reconnectTimer;
  bool _registered = false;
  bool _isDisposed = false;

  final Map<String, Completer<MeshFetchResult>> _pending = {};
  final Map<String, _ChunkedResponse> _chunked = {};

  Future<MeshFetchResult> fetch(String hostPeerId, String path) async {
    final requestPath = path.isEmpty ? '/' : path;
    try {
      await _ensureConnected();
    } catch (error) {
      return MeshFetchResult(
        success: false,
        status: 0,
        mime: 'text/plain',
        error: 'Unable to connect to mesh relay: $error',
      );
    }

    final requestId = _randomHex(16);
    final completer = Completer<MeshFetchResult>();
    _pending[requestId] = completer;

    _send({
      'type': 'mesh-request',
      'to': hostPeerId,
      'from': saturnPeerId,
      'requestId': requestId,
      'path': requestPath.startsWith('/') ? requestPath : '/$requestPath',
    });

    try {
      return await completer.future.timeout(
        _requestTimeout,
        onTimeout: () {
          _pending.remove(requestId);
          _chunked.remove(requestId);
          return const MeshFetchResult(
            success: false,
            status: 0,
            mime: 'text/plain',
            error: 'Mesh request timed out',
          );
        },
      );
    } finally {
      _pending.remove(requestId);
      _chunked.remove(requestId);
    }
  }

  void dispose() {
    _isDisposed = true;
    _keepaliveTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
  }

  Future<void> _ensureConnected() {
    if (_registered && _channel != null) {
      return Future.value();
    }

    final existingConnection = _connecting;
    if (existingConnection != null) {
      return _withRegistrationTimeout(existingConnection.future);
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final completer = Completer<void>();
    _connecting = completer;
    _connect(completer);
    return _withRegistrationTimeout(completer.future);
  }

  Future<void> _withRegistrationTimeout(Future<void> future) {
    return future.timeout(
      AppConstants.connectTimeout,
      onTimeout: () {
        _connecting = null;
        _channel?.sink.close();
        throw TimeoutException('Mesh relay registration timed out');
      },
    );
  }

  Future<void> _connect(Completer<void> completer) async {
    try {
      final channel = WebSocketChannel.connect(
        Uri.parse(AppConstants.relayBase),
      );
      _channel = channel;
      channel.stream.listen(
        _handleMessage,
        onError: (Object error) => _handleDisconnect(error),
        onDone: () => _handleDisconnect(),
        cancelOnError: true,
      );

      await channel.ready.timeout(AppConstants.connectTimeout);
      _send({'type': 'register', 'id': saturnPeerId});
    } catch (error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
      _connecting = null;
      _handleDisconnect(error);
    }
  }

  void _handleMessage(Object? message) {
    final raw = _decodeMessage(message);
    if (raw == null) {
      return;
    }

    final type = raw['type'];
    if (type == 'registered') {
      _registered = true;
      _startKeepalive();
      final connecting = _connecting;
      _connecting = null;
      if (connecting != null && !connecting.isCompleted) {
        connecting.complete();
      }
      return;
    }

    if (type == 'mesh-response') {
      _handleResponse(raw);
      return;
    }

    if (type == 'mesh-response-start') {
      _handleResponseStart(raw);
      return;
    }

    if (type == 'mesh-chunk') {
      _handleChunk(raw);
      return;
    }

    if (type == 'mesh-response-end') {
      _handleResponseEnd(raw);
    }
  }

  void _handleResponse(Map<String, dynamic> raw) {
    final requestId = raw['requestId'];
    if (requestId is! String) {
      return;
    }

    final body = raw['body'];
    if (body is! String) {
      _completeRequest(
        requestId,
        _errorResult(raw, 'Mesh response did not include a body'),
      );
      return;
    }

    try {
      _completeRequest(
        requestId,
        MeshFetchResult(
          success: _statusCode(raw) < 400,
          status: _statusCode(raw),
          mime: _mime(raw),
          bytes: base64Decode(body),
        ),
      );
    } on FormatException catch (error) {
      _completeRequest(requestId, _errorResult(raw, error.message));
    }
  }

  void _handleResponseStart(Map<String, dynamic> raw) {
    final requestId = raw['requestId'];
    final total = raw['total'];
    if (requestId is! String || total is! num || total <= 0) {
      return;
    }

    _chunked[requestId] = _ChunkedResponse(
      total: total.toInt(),
      status: _statusCode(raw),
      mime: _mime(raw),
    );
  }

  void _handleChunk(Map<String, dynamic> raw) {
    final requestId = raw['requestId'];
    final index = raw['index'];
    final data = raw['data'];
    if (requestId is! String ||
        index is! num ||
        data is! String ||
        !_chunked.containsKey(requestId)) {
      return;
    }

    try {
      _chunked[requestId]!.chunks[index.toInt()] = base64Decode(data);
    } on FormatException {
      _completeRequest(
        requestId,
        _errorResult(raw, 'Mesh chunk contained invalid base64 data'),
      );
    }
  }

  void _handleResponseEnd(Map<String, dynamic> raw) {
    final requestId = raw['requestId'];
    if (requestId is! String) {
      return;
    }

    final response = _chunked[requestId];
    if (response == null) {
      return;
    }

    if (response.chunks.length != response.total) {
      _completeRequest(
        requestId,
        MeshFetchResult(
          success: false,
          status: response.status,
          mime: response.mime,
          error: 'Mesh response ended before all chunks arrived',
        ),
      );
      return;
    }

    final builder = BytesBuilder(copy: false);
    for (var index = 0; index < response.total; index++) {
      final chunk = response.chunks[index];
      if (chunk == null) {
        _completeRequest(
          requestId,
          MeshFetchResult(
            success: false,
            status: response.status,
            mime: response.mime,
            error: 'Mesh response is missing chunk $index',
          ),
        );
        return;
      }
      builder.add(chunk);
    }

    _completeRequest(
      requestId,
      MeshFetchResult(
        success: response.status < 400,
        status: response.status,
        mime: response.mime,
        bytes: builder.takeBytes(),
      ),
    );
  }

  void _completeRequest(String requestId, MeshFetchResult result) {
    final completer = _pending.remove(requestId);
    _chunked.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  Map<String, dynamic>? _decodeMessage(Object? message) {
    try {
      final text = switch (message) {
        String value => value,
        List<int> value => utf8.decode(value),
        _ => null,
      };
      if (text == null) {
        return null;
      }

      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  int _statusCode(Map<String, dynamic> raw) {
    final status = raw['status'];
    return status is num ? status.toInt() : 0;
  }

  String _mime(Map<String, dynamic> raw) {
    final mime = raw['mime'];
    return mime is String && mime.isNotEmpty
        ? mime
        : 'application/octet-stream';
  }

  MeshFetchResult _errorResult(Map<String, dynamic> raw, String error) {
    return MeshFetchResult(
      success: false,
      status: _statusCode(raw),
      mime: _mime(raw),
      error: error,
    );
  }

  void _send(Map<String, Object?> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void _startKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(_keepaliveInterval, (_) {
      if (_registered) {
        _send({'type': 'ping'});
      }
    });
  }

  void _handleDisconnect([Object? error]) {
    _registered = false;
    _channel = null;
    _keepaliveTimer?.cancel();

    final connecting = _connecting;
    _connecting = null;
    if (connecting != null && !connecting.isCompleted && error != null) {
      connecting.completeError(error);
    }

    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          const MeshFetchResult(
            success: false,
            status: 0,
            mime: 'text/plain',
            error: 'Mesh relay disconnected',
          ),
        );
      }
    }
    _pending.clear();
    _chunked.clear();

    if (!_isDisposed) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive ?? false) {
      return;
    }

    _reconnectTimer = Timer(_reconnectDelay, () {
      if (!_isDisposed && !_registered) {
        _ensureConnected().catchError((Object _) {});
      }
    });
  }

  static String _randomHex(int bytes) {
    final buffer = StringBuffer();
    for (var index = 0; index < bytes; index++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class _ChunkedResponse {
  _ChunkedResponse({
    required this.total,
    required this.status,
    required this.mime,
  });

  final int total;
  final int status;
  final String mime;
  final Map<int, Uint8List> chunks = {};
}
