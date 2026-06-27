import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/saturn_theme.dart';
import '../../mesh/resolver/mesh_resolver.dart';
import '../../mesh/providers/mesh_providers.dart';
import '../../mesh/services/mesh_client.dart';
import '../../mesh/services/mesh_media_bridge.dart';
import '../providers/browser_provider.dart';
import 'address_bar.dart';
import 'browser_controls.dart';
import 'saturn_home.dart';

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  InAppWebViewController? _webViewController;
  bool _showHome = true;
  String? _currentHostPeerId;
  String? _currentMeshHandle;
  MeshMediaBridge? _mediaBridge;

  @override
  void dispose() {
    final bridge = _mediaBridge;
    if (bridge != null) {
      unawaited(bridge.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(browserProvider);

    return Scaffold(
      backgroundColor: SaturnTheme.voidBg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: SaturnTheme.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
                    child: Row(
                      children: [
                        BrowserControls(
                          onBack: _goBack,
                          onForward: _goForward,
                          onReloadOrStop: _reloadOrStop,
                          onHome: () => _navigate(AppConstants.homeUrl),
                        ),
                        Expanded(child: AddressBar(onSubmitted: _navigate)),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          splashRadius: 18,
                          onPressed: () {},
                          icon: const Icon(
                            Icons.more_vert,
                            color: SaturnTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (state.isLoading)
                    LinearProgressIndicator(
                      minHeight: 2,
                      value: state.loadProgress <= 0
                          ? null
                          : state.loadProgress,
                      color: state.isMeshPage
                          ? SaturnTheme.meshAccent
                          : SaturnTheme.cyan,
                      backgroundColor: SaturnTheme.border,
                    ),
                  const Divider(height: 1),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  SaturnHome(onNavigate: _navigate),
                  Offstage(
                    offstage: _showHome,
                    child: InAppWebView(
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        useShouldOverrideUrlLoading: true,
                        resourceCustomSchemes: [AppConstants.meshScheme],
                        mixedContentMode:
                            MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                        hardwareAcceleration: true,
                      ),
                      onWebViewCreated: (controller) {
                        _webViewController = controller;
                      },
                      onLoadResourceWithCustomScheme: (controller, request) async {
                        final url = request.url.toString();
                        final requestHeaders = request.headers ?? {};
                        final rangeHeader = _headerValue(
                          requestHeaders,
                          'range',
                        );

                        final hostPeerId = _currentHostPeerId;
                        if (hostPeerId == null) {
                          return null;
                        }

                        final uri = Uri.parse(url);
                        final path = uri.path.isEmpty ? '/' : uri.path;
                        final query = uri.hasQuery ? '?${uri.query}' : '';
                        final fullPath = '$path$query';
                        final shouldLogResource =
                            _isMediaOrPlaylistPath(fullPath) ||
                            rangeHeader != null;
                        if (shouldLogResource) {
                          _logMeshResource('custom request URL: $url');
                          _logMeshResource(
                            'custom request Range: ${rangeHeader ?? '(none)'}',
                          );
                        }

                        final result = await ref
                            .read(meshClientProvider)
                            .fetch(
                              hostPeerId,
                              fullPath,
                              headers: requestHeaders,
                              range: rangeHeader,
                            );

                        if (shouldLogResource) {
                          _logMeshResource(
                            'custom response status: ${result.status}',
                          );
                          _logMeshResource(
                            'custom response Content-Type: ${result.mime}',
                          );
                          _logMeshResource(
                            'custom response Content-Length: '
                            '${_headerValue(result.headers, 'content-length') ?? result.bytes?.length ?? '(none)'}',
                          );
                          _logMeshResource(
                            'custom response Content-Range: '
                            '${_headerValue(result.headers, 'content-range') ?? '(none)'}',
                          );
                        }

                        if (!result.success || result.bytes == null) {
                          return null;
                        }

                        final bytes = await _rewritePlaylistMediaUrlsIfNeeded(
                          uri,
                          result,
                          hostPeerId,
                        );

                        return CustomSchemeResponse(
                          data: bytes,
                          contentType: result.mime,
                          contentEncoding: 'UTF-8',
                        );
                      },
                      shouldOverrideUrlLoading: (controller, action) async {
                        final url = action.request.url?.toString();
                        if (url == null) {
                          return NavigationActionPolicy.ALLOW;
                        }

                        if (url.startsWith(AppConstants.meshSchemePrefix)) {
                          final hostPeerId = _currentHostPeerId;
                          if (hostPeerId != null && _isCurrentMeshHandle(url)) {
                            await _fetchMeshContent(
                              hostPeerId,
                              _pathFromMeshUrl(url),
                              url,
                            );
                          } else {
                            await _resolveMesh(url);
                          }
                          return NavigationActionPolicy.CANCEL;
                        }

                        final meshUrl = _meshUrlForRelativeNavigation(url);
                        if (meshUrl != null && _currentHostPeerId != null) {
                          await _fetchMeshContent(
                            _currentHostPeerId!,
                            _pathFromMeshUrl(meshUrl),
                            meshUrl,
                          );
                          return NavigationActionPolicy.CANCEL;
                        }

                        return NavigationActionPolicy.ALLOW;
                      },
                      onLoadStart: (controller, url) {
                        ref
                            .read(browserProvider.notifier)
                            .setLoading(true, progress: 0);
                        if (url != null &&
                            !ref
                                .read(browserProvider)
                                .addressBarText
                                .startsWith(AppConstants.meshSchemePrefix)) {
                          ref
                              .read(browserProvider.notifier)
                              .setAddressBar(url.toString());
                        }
                      },
                      onProgressChanged: (controller, progress) {
                        ref
                            .read(browserProvider.notifier)
                            .setProgress(progress / 100);
                      },
                      onTitleChanged: (controller, title) {
                        ref.read(browserProvider.notifier).setTitle(title);
                      },
                      onLoadStop: (controller, url) async {
                        final notifier = ref.read(browserProvider.notifier);
                        notifier.setLoading(false);
                        notifier.setNavState(
                          canGoBack: await controller.canGoBack(),
                          canGoForward: await controller.canGoForward(),
                        );
                      },
                      onReceivedError: (controller, request, error) {
                        ref.read(browserProvider.notifier).setLoading(false);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _navigate(String url) async {
    final notifier = ref.read(browserProvider.notifier);
    notifier.setUrl(url);

    if (url == AppConstants.homeUrl) {
      _clearCurrentMeshHost();
      setState(() => _showHome = true);
      notifier.setLoading(false);
      notifier.setNavState(canGoBack: false, canGoForward: false);
      return;
    }

    if (url.startsWith(AppConstants.meshSchemePrefix)) {
      await _resolveMesh(url);
      return;
    }

    _clearCurrentMeshHost();
    setState(() => _showHome = false);
    await _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _resolveMesh(String meshUrl) async {
    final notifier = ref.read(browserProvider.notifier);
    notifier.setAddressBar(meshUrl);
    notifier.setLoading(true);
    setState(() => _showHome = false);

    final result = await ref.read(meshResolverProvider).resolve(meshUrl);
    if (!mounted) {
      return;
    }

    if (result.status == MeshResolveStatus.success && result.peerId != null) {
      final handle = result.handle ?? _handleFromMeshUrl(meshUrl);
      _currentHostPeerId = result.peerId;
      _currentMeshHandle = handle;
      _registerMeshMediaHost(handle, result.peerId!);
      await _fetchMeshContent(
        result.peerId!,
        _pathFromMeshUrl(meshUrl),
        meshUrl,
      );
      return;
    }

    _clearCurrentMeshHost();
    notifier.setLoading(false);
    _showMeshError(result);
  }

  Future<void> _fetchMeshContent(
    String hostPeerId,
    String path,
    String displayUrl,
  ) async {
    final notifier = ref.read(browserProvider.notifier);
    notifier.setAddressBar(displayUrl);
    notifier.setLoading(true);
    setState(() => _showHome = false);

    final result = await ref.read(meshClientProvider).fetch(hostPeerId, path);
    if (!mounted) {
      return;
    }

    if (result.success && result.bytes != null) {
      try {
        final html = await _prepareMeshHtml(
          utf8.decode(result.bytes!),
          result.mime,
          hostPeerId,
        );
        await _webViewController?.loadData(
          data: html,
          mimeType: result.mime,
          encoding: 'UTF-8',
          baseUrl: WebUri('mesh://$_currentMeshHandle/'),
          historyUrl: WebUri(displayUrl),
        );
        notifier.setAddressBar(displayUrl);
      } on FormatException catch (error) {
        notifier.setLoading(false);
        _showMeshFetchError(
          MeshFetchResult(
            success: false,
            status: result.status,
            mime: result.mime,
            error: error.message,
          ),
        );
      }
      return;
    }

    notifier.setLoading(false);
    _showMeshFetchError(result);
  }

  Future<void> _goBack() async {
    if (await _webViewController?.canGoBack() ?? false) {
      await _webViewController?.goBack();
    }
  }

  Future<void> _goForward() async {
    if (await _webViewController?.canGoForward() ?? false) {
      await _webViewController?.goForward();
    }
  }

  Future<void> _reloadOrStop() async {
    final state = ref.read(browserProvider);
    if (state.isLoading) {
      await _webViewController?.stopLoading();
      ref.read(browserProvider.notifier).setLoading(false);
    } else if (_showHome) {
      await _navigate(AppConstants.homeUrl);
    } else {
      await _webViewController?.reload();
    }
  }

  void _showMeshError(MeshResolveResult result) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SaturnTheme.surface,
      barrierColor: Colors.black54,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mesh resolve failed',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: SaturnTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Status: ${result.status.name}',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.meshAccent,
                  fontSize: 13,
                ),
              ),
              if (result.handle != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Handle: ${result.handle}',
                  style: SaturnTheme.mono.copyWith(
                    color: SaturnTheme.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
              if (result.errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  result.errorMessage!,
                  style: const TextStyle(color: SaturnTheme.textSecondary),
                ),
              ],
              const SizedBox(height: 18),
            ],
          ),
        );
      },
    );
  }

  void _showMeshFetchError(MeshFetchResult result) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SaturnTheme.surface,
      barrierColor: Colors.black54,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mesh fetch failed',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: SaturnTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Status: ${result.status}',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.meshAccent,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'MIME: ${result.mime}',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              if (result.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  result.error!,
                  style: const TextStyle(color: SaturnTheme.textSecondary),
                ),
              ],
              const SizedBox(height: 18),
            ],
          ),
        );
      },
    );
  }

  bool _isCurrentMeshHandle(String meshUrl) {
    final handle = _handleFromMeshUrl(meshUrl);
    return handle != null && handle == _currentMeshHandle;
  }

  String? _meshUrlForRelativeNavigation(String url) {
    final handle = _currentMeshHandle;
    if (handle == null) {
      return null;
    }

    if (url.startsWith('about:blank')) {
      final suffix = url.substring('about:blank'.length);
      if (suffix.startsWith('/')) {
        return '${AppConstants.meshSchemePrefix}$handle$suffix';
      }
      if (suffix.startsWith('?')) {
        return '${AppConstants.meshSchemePrefix}$handle/$suffix';
      }
    }

    if (url.startsWith('/')) {
      return '${AppConstants.meshSchemePrefix}$handle$url';
    }

    return null;
  }

  String _pathFromMeshUrl(String meshUrl) {
    final withoutScheme = meshUrl.startsWith(AppConstants.meshSchemePrefix)
        ? meshUrl.substring(AppConstants.meshSchemePrefix.length)
        : meshUrl;
    final suffixStart = withoutScheme.indexOf(RegExp(r'[/#?]'));
    if (suffixStart == -1) {
      return '/';
    }

    final suffix = withoutScheme.substring(suffixStart);
    if (suffix.startsWith('/')) {
      final fragmentStart = suffix.indexOf('#');
      final path = fragmentStart == -1
          ? suffix
          : suffix.substring(0, fragmentStart);
      return path.isEmpty ? '/' : path;
    }

    if (suffix.startsWith('?')) {
      final fragmentStart = suffix.indexOf('#');
      final query = fragmentStart == -1
          ? suffix
          : suffix.substring(0, fragmentStart);
      return '/$query';
    }

    return '/';
  }

  String? _handleFromMeshUrl(String meshUrl) {
    if (!meshUrl.startsWith(AppConstants.meshSchemePrefix)) {
      return null;
    }

    final withoutScheme = meshUrl.substring(
      AppConstants.meshSchemePrefix.length,
    );
    final suffixStart = withoutScheme.indexOf(RegExp(r'[/#?]'));
    final handle = suffixStart == -1
        ? withoutScheme
        : withoutScheme.substring(0, suffixStart);
    return handle.isEmpty ? null : handle;
  }

  void _registerMeshMediaHost(String? handle, String peerId) {
    if (handle == null || handle.isEmpty) {
      return;
    }

    final bridge = _mediaBridge ??= MeshMediaBridge(
      ref.read(meshClientProvider),
      log: _logMeshResource,
    );
    bridge.registerHost(handle, peerId);
  }

  Future<Uint8List> _rewritePlaylistMediaUrlsIfNeeded(
    Uri uri,
    MeshFetchResult result,
    String hostPeerId,
  ) async {
    final bytes = result.bytes!;
    final handle = _currentMeshHandle;
    if (handle == null || !_isPlaylistRequest(uri)) {
      return bytes;
    }

    try {
      _registerMeshMediaHost(handle, hostPeerId);
      final decoded = jsonDecode(utf8.decode(bytes));
      final rewritten = await _rewritePlaylistValue(decoded, handle);
      if (!rewritten.changed) {
        return bytes;
      }

      _logMeshResource(
        'playlist media URLs rewritten through localhost bridge',
      );
      return Uint8List.fromList(utf8.encode(jsonEncode(rewritten.value)));
    } on Object catch (error) {
      _logMeshResource('playlist rewrite skipped: $error');
      return bytes;
    }
  }

  Future<String> _prepareMeshHtml(
    String html,
    String mime,
    String hostPeerId,
  ) async {
    final handle = _currentMeshHandle;
    if (handle == null || !_isHtmlMime(mime)) {
      return html;
    }

    _registerMeshMediaHost(handle, hostPeerId);
    final bridge = _mediaBridge ??= MeshMediaBridge(
      ref.read(meshClientProvider),
      log: _logMeshResource,
    );
    final bridgeBase = (await bridge.baseUrl(handle)).toString();
    final script = _meshBridgeFetchScript(handle, bridgeBase);
    _logMeshResource('mesh HTML fetch shim installed for $handle');

    final head = RegExp(
      r'<head(\s[^>]*)?>',
      caseSensitive: false,
    ).firstMatch(html);
    if (head == null) {
      return '$script$html';
    }

    return html.replaceRange(head.end, head.end, script);
  }

  bool _isHtmlMime(String mime) {
    return mime.toLowerCase().contains('html');
  }

  String _meshBridgeFetchScript(String handle, String bridgeBase) {
    final meshBase = '${AppConstants.meshSchemePrefix}$handle/';
    return '''
<script>
(() => {
  const meshBase = ${jsonEncode(meshBase)};
  const meshHost = ${jsonEncode(handle)};
  const bridgeBase = ${jsonEncode(bridgeBase)};
  const nativeFetch = window.fetch.bind(window);

  window.fetch = function(input, init) {
    const raw = typeof input === 'string' ? input : input && input.url;
    if (raw) {
      try {
        const resolved = new URL(raw, meshBase);
        if (
          resolved.protocol === 'mesh:' &&
          resolved.host === meshHost &&
          (resolved.pathname === '/playlist.json' ||
            resolved.pathname.startsWith('/media/'))
        ) {
          const target = bridgeBase + resolved.pathname + resolved.search;
          console.log('[saturn mesh bridge] fetch ' + target);
          return nativeFetch(target, init);
        }
      } catch (_) {}
    }

    return nativeFetch(input, init);
  };
})();
</script>
''';
  }

  Future<_PlaylistRewriteResult> _rewritePlaylistValue(
    Object? value,
    String handle,
  ) async {
    if (value is String) {
      final mediaPath = _relativeMeshMediaPath(value);
      if (mediaPath == null) {
        return _PlaylistRewriteResult(value, changed: false);
      }

      final bridge = _mediaBridge ??= MeshMediaBridge(
        ref.read(meshClientProvider),
        log: _logMeshResource,
      );
      final mediaUrl = await bridge.mediaUrl(handle, mediaPath);
      return _PlaylistRewriteResult(mediaUrl.toString(), changed: true);
    }

    if (value is List) {
      var changed = false;
      final items = <Object?>[];
      for (final item in value) {
        final rewritten = await _rewritePlaylistValue(item, handle);
        changed = changed || rewritten.changed;
        items.add(rewritten.value);
      }
      return _PlaylistRewriteResult(items, changed: changed);
    }

    if (value is Map) {
      var changed = false;
      final map = <Object?, Object?>{};
      for (final entry in value.entries) {
        final rewritten = await _rewritePlaylistValue(entry.value, handle);
        changed = changed || rewritten.changed;
        map[entry.key] = rewritten.value;
      }
      return _PlaylistRewriteResult(map, changed: changed);
    }

    return _PlaylistRewriteResult(value, changed: false);
  }

  bool _isPlaylistRequest(Uri uri) {
    return uri.pathSegments.isNotEmpty &&
        uri.pathSegments.last == 'playlist.json';
  }

  bool _isMediaOrPlaylistPath(String path) {
    final uri = Uri.tryParse(path);
    if (uri == null) {
      return false;
    }

    return uri.path == '/playlist.json' || uri.path.startsWith('/media/');
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

  String? _headerValue(Map<String, String> headers, String name) {
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

  void _logMeshResource(String message) {
    debugPrint('[mesh-media] $message');
  }

  void _clearCurrentMeshHost() {
    _currentHostPeerId = null;
    _currentMeshHandle = null;
  }
}

class _PlaylistRewriteResult {
  const _PlaylistRewriteResult(this.value, {required this.changed});

  final Object? value;
  final bool changed;
}
