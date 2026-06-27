import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mesh_client.dart';

class MeshMediaBridge {
  MeshMediaBridge(this._meshClient, {void Function(String message)? log})
    : _log = log ?? print;

  final MeshClient _meshClient;
  final void Function(String message) _log;
  final Map<String, String> _peerIdsByHost = {};

  HttpServer? _server;
  Future<HttpServer>? _starting;

  int? get port => _server?.port;

  void registerHost(String host, String peerId) {
    _peerIdsByHost[host] = peerId;
  }

  Future<void> dispose() async {
    final server = _server;
    _server = null;
    _starting = null;
    await server?.close(force: true);
  }

  Future<Uri> baseUrl(String host) async {
    final server = await _ensureStarted();
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: ['mesh-media', host],
    );
  }

  Future<Uri> mediaUrl(String host, String mediaPath) async {
    final server = await _ensureStarted();
    final uri = Uri.parse(mediaPath);
    final pathSegments = uri.pathSegments.isEmpty
        ? mediaPath.split('/').where((part) => part.isNotEmpty).toList()
        : uri.pathSegments;

    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: ['mesh-media', host, ...pathSegments],
      query: uri.hasQuery ? uri.query : null,
    );
  }

  Future<HttpServer> _ensureStarted() async {
    final server = _server;
    if (server != null) {
      return server;
    }

    final starting = _starting;
    if (starting != null) {
      return starting;
    }

    final future = HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _starting = future;
    final started = await future;
    _server = started;
    _starting = null;
    started.listen(_handleRequest);
    _log('[mesh-media] bridge listening on 127.0.0.1:${started.port}');
    return started;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _applyCorsHeaders(request.response);
    final headers = _requestHeaders(request);
    final range = request.headers.value(HttpHeaders.rangeHeader);
    _log('bridge request ${request.method} ${request.uri}');
    _log('bridge Range: ${range ?? '(none)'}');

    try {
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.length < 3 || segments.first != 'mesh-media') {
        await _sendPlain(request.response, HttpStatus.notFound, 'Not found');
        return;
      }

      final host = segments[1];
      final peerId = _peerIdsByHost[host];
      if (peerId == null) {
        await _sendPlain(
          request.response,
          HttpStatus.notFound,
          'Unknown mesh media host',
        );
        return;
      }

      final mediaPath =
          '/${segments.skip(2).join('/')}'
          '${request.uri.hasQuery ? '?${request.uri.query}' : ''}';
      if (!_isAllowedBridgePath(mediaPath)) {
        await _sendPlain(
          request.response,
          HttpStatus.notFound,
          'Unsupported mesh media path',
        );
        return;
      }

      final result = await _meshClient.fetch(
        peerId,
        mediaPath,
        headers: headers,
        range: range,
      );

      _log('bridge response status: ${result.status}');
      _log('bridge response Content-Type: ${result.mime}');
      var responseBytes = result.bytes;
      final isPlaylist = _isPlaylistPath(mediaPath);
      if (result.success && responseBytes != null && isPlaylist) {
        responseBytes = await _rewritePlaylistBytes(host, responseBytes);
      }
      _log(
        'bridge response Content-Length: '
        '${isPlaylist ? responseBytes?.length : _header(result.headers, HttpHeaders.contentLengthHeader) ?? responseBytes?.length ?? '(none)'}',
      );
      _log(
        'bridge response Content-Range: '
        '${_header(result.headers, HttpHeaders.contentRangeHeader) ?? '(none)'}',
      );

      if (!result.success || responseBytes == null) {
        await _sendPlain(
          request.response,
          result.status == 0 ? HttpStatus.badGateway : result.status,
          result.error ?? 'Mesh media fetch failed',
        );
        return;
      }

      request.response.statusCode = result.status;
      request.response.headers.set(HttpHeaders.contentTypeHeader, result.mime);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      final contentRange = _header(
        result.headers,
        HttpHeaders.contentRangeHeader,
      );
      if (contentRange != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          contentRange,
        );
      }

      request.response.headers.set(
        HttpHeaders.contentLengthHeader,
        _header(result.headers, HttpHeaders.contentLengthHeader) ??
            responseBytes.length.toString(),
      );
      if (isPlaylist) {
        request.response.headers.set(
          HttpHeaders.contentLengthHeader,
          responseBytes.length.toString(),
        );
      }
      request.response.add(responseBytes);
      await request.response.close();
    } catch (error) {
      _log('bridge error: $error');
      await _sendPlain(
        request.response,
        HttpStatus.internalServerError,
        'Mesh media bridge error',
      );
    }
  }

  Map<String, String> _requestHeaders(HttpRequest request) {
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      if (values.isNotEmpty) {
        headers[name] = values.join(', ');
      }
    });
    return headers;
  }

  Future<void> _sendPlain(
    HttpResponse response,
    int status,
    String message,
  ) async {
    _applyCorsHeaders(response);
    response.statusCode = status;
    response.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
    response.write(message);
    await response.close();
  }

  void _applyCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Range, Content-Type, Accept, Origin',
    );
    response.headers.set(
      'Access-Control-Expose-Headers',
      'Accept-Ranges, Content-Length, Content-Range, Content-Type',
    );
  }

  String? _header(Map<String, String> headers, String name) {
    final exact = headers[name];
    if (exact != null) {
      return exact;
    }

    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry.value;
      }
    }
    return null;
  }

  bool _isPlaylistPath(String path) {
    final uri = Uri.tryParse(path);
    return uri != null &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.last == 'playlist.json';
  }

  bool _isAllowedBridgePath(String path) {
    final uri = Uri.tryParse(path);
    if (uri == null) {
      return false;
    }

    return uri.path == '/playlist.json' || uri.path.startsWith('/media/');
  }

  Future<Uint8List> _rewritePlaylistBytes(String host, Uint8List bytes) async {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      final rewritten = await _rewritePlaylistValue(host, decoded);
      if (!rewritten.changed) {
        return bytes;
      }

      _log('bridge playlist media URLs rewritten');
      return Uint8List.fromList(utf8.encode(jsonEncode(rewritten.value)));
    } on Object catch (error) {
      _log('bridge playlist rewrite skipped: $error');
      return bytes;
    }
  }

  Future<_PlaylistRewriteResult> _rewritePlaylistValue(
    String host,
    Object? value,
  ) async {
    if (value is String) {
      final mediaPath = _relativeMeshMediaPath(value);
      if (mediaPath == null) {
        return _PlaylistRewriteResult(value, changed: false);
      }

      final url = await mediaUrl(host, mediaPath);
      return _PlaylistRewriteResult(url.toString(), changed: true);
    }

    if (value is List) {
      var changed = false;
      final items = <Object?>[];
      for (final item in value) {
        final rewritten = await _rewritePlaylistValue(host, item);
        changed = changed || rewritten.changed;
        items.add(rewritten.value);
      }
      return _PlaylistRewriteResult(items, changed: changed);
    }

    if (value is Map) {
      var changed = false;
      final map = <String, Object?>{};
      for (final entry in value.entries) {
        final rewritten = await _rewritePlaylistValue(host, entry.value);
        changed = changed || rewritten.changed;
        map[entry.key.toString()] = rewritten.value;
      }
      return _PlaylistRewriteResult(map, changed: changed);
    }

    return _PlaylistRewriteResult(value, changed: false);
  }

  String? _relativeMeshMediaPath(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.hasScheme) {
      return null;
    }

    final path = uri.path.startsWith('/') ? uri.path : '/${uri.path}';
    if (!path.toLowerCase().startsWith('/media/')) {
      return null;
    }

    return '$path${uri.hasQuery ? '?${uri.query}' : ''}';
  }
}

class _PlaylistRewriteResult {
  const _PlaylistRewriteResult(this.value, {required this.changed});

  final Object? value;
  final bool changed;
}
