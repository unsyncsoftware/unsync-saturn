import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'saturn_home.dart';

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  InAppWebViewController? _webViewController;
  final Map<String, _TabRuntime> _tabRuntimes = {'tab-1': _TabRuntime()};
  final Set<String> _bookmarkedUrls = {};
  MeshMediaBridge? _mediaBridge;

  _TabRuntime get _activeRuntime {
    final activeTabId = ref.read(browserProvider).activeTabId;
    return _runtimeFor(activeTabId);
  }

  String? get _currentHostPeerId => _activeRuntime.hostPeerId;
  set _currentHostPeerId(String? value) => _activeRuntime.hostPeerId = value;

  String? get _currentMeshHandle => _activeRuntime.meshHandle;
  set _currentMeshHandle(String? value) => _activeRuntime.meshHandle = value;

  _TabRuntime _runtimeFor(String tabId) {
    return _tabRuntimes.putIfAbsent(tabId, _TabRuntime.new);
  }

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
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Bookmark',
                          visualDensity: VisualDensity.compact,
                          splashRadius: 18,
                          onPressed: _toggleBookmark,
                          icon: Icon(
                            _isActiveUrlBookmarked
                                ? Icons.bookmark
                                : Icons.bookmark_border,
                            color: _isActiveUrlBookmarked
                                ? SaturnTheme.meshAccent
                                : SaturnTheme.textSecondary,
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 720),
                              child: AddressBar(onSubmitted: _navigate),
                            ),
                          ),
                        ),
                        _BrowserMenuButton(
                          canGoBack: state.canGoBack,
                          canGoForward: state.canGoForward,
                          isLoading: state.isLoading,
                          onSelected: _handleMenuAction,
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
                    offstage: _activeRuntime.showHome,
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
                            await _openMeshUrl(url);
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
                        final notifier = ref.read(browserProvider.notifier);
                        notifier.setLoading(true, progress: 0);
                        if (url != null &&
                            !ref
                                .read(browserProvider)
                                .addressBarText
                                .startsWith(AppConstants.meshSchemePrefix)) {
                          final text = url.toString();
                          if (!text.startsWith(AppConstants.meshSchemePrefix)) {
                            notifier.setUrl(text);
                          }
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
                        if (url != null) {
                          final text = url.toString();
                          if (!text.startsWith(AppConstants.meshSchemePrefix)) {
                            notifier.setUrl(text);
                          }
                        }
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
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          height: 56,
          decoration: const BoxDecoration(
            color: SaturnTheme.surface,
            border: Border(top: BorderSide(color: SaturnTheme.border)),
          ),
          child: Center(
            child: IconButton(
              tooltip: 'Tabs',
              splashRadius: 22,
              onPressed: _showTabSwitcher,
              icon: Badge.count(
                count: state.tabs.length,
                backgroundColor: SaturnTheme.meshAccent,
                textColor: SaturnTheme.voidBg,
                child: const Icon(
                  Icons.tab_outlined,
                  color: SaturnTheme.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _newTab() {
    final tabId = ref.read(browserProvider.notifier).newTab();
    _runtimeFor(tabId).showHome = true;
    unawaited(_webViewController?.stopLoading());
    setState(() {});
  }

  void _toggleBookmark() {
    final url = ref.read(browserProvider).currentUrl;
    if (url == AppConstants.homeUrl || url.isEmpty) {
      return;
    }

    setState(() {
      if (!_bookmarkedUrls.add(url)) {
        _bookmarkedUrls.remove(url);
      }
    });
  }

  bool get _isActiveUrlBookmarked {
    final url = ref.watch(browserProvider).currentUrl;
    return url != AppConstants.homeUrl && _bookmarkedUrls.contains(url);
  }

  void _handleMenuAction(_BrowserMenuAction action) {
    switch (action) {
      case _BrowserMenuAction.back:
        unawaited(_goBack());
      case _BrowserMenuAction.forward:
        unawaited(_goForward());
      case _BrowserMenuAction.reloadOrHome:
        unawaited(_reloadOrStop());
      case _BrowserMenuAction.history:
      case _BrowserMenuAction.bookmarks:
      case _BrowserMenuAction.downloads:
      case _BrowserMenuAction.help:
      case _BrowserMenuAction.settings:
        _showPlaceholderSheet(action.label);
      case _BrowserMenuAction.exit:
        SystemNavigator.pop();
    }
  }

  void _showPlaceholderSheet(String title) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SaturnTheme.surface,
      barrierColor: Colors.black54,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: SaturnTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Coming soon.',
                  style: TextStyle(color: SaturnTheme.textSecondary),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showTabSwitcher() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SaturnTheme.surface,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(browserProvider);
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Tabs',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: SaturnTheme.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'New tab',
                          onPressed: () {
                            Navigator.pop(context);
                            _newTab();
                          },
                          icon: const Icon(
                            Icons.add,
                            color: SaturnTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.55,
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: state.tabs.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final tab = state.tabs[index];
                          return _TabListTile(
                            tab: tab,
                            active: tab.id == state.activeTabId,
                            canClose: state.tabs.length > 1,
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_switchTab(tab.id));
                            },
                            onClose: () => unawaited(_closeTab(tab.id)),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _closeTab(String tabId) async {
    final wasActive = ref.read(browserProvider).activeTabId == tabId;
    _tabRuntimes.remove(tabId);
    ref.read(browserProvider.notifier).closeTab(tabId);
    if (!mounted) {
      return;
    }

    if (wasActive) {
      setState(() {});
      await _restoreActiveTab();
      return;
    }

    setState(() {});
  }

  Future<void> _switchTab(String tabId) async {
    if (ref.read(browserProvider).activeTabId == tabId) {
      return;
    }

    await _webViewController?.stopLoading();
    ref.read(browserProvider.notifier).switchTab(tabId);
    if (!mounted) {
      return;
    }

    setState(() {});
    await _restoreActiveTab();
  }

  Future<void> _restoreActiveTab() async {
    final state = ref.read(browserProvider);
    final runtime = _runtimeFor(state.activeTabId);
    if (runtime.showHome || state.currentUrl == AppConstants.homeUrl) {
      runtime.showHome = true;
      ref.read(browserProvider.notifier).setLoading(false);
      setState(() {});
      return;
    }

    if (state.currentUrl.startsWith(AppConstants.meshSchemePrefix)) {
      await _openMeshUrl(state.currentUrl);
      return;
    }

    _clearCurrentMeshHost();
    runtime.showHome = false;
    setState(() {});
    await _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri(state.currentUrl)),
    );
  }

  Future<void> _navigate(String url) async {
    final notifier = ref.read(browserProvider.notifier);

    if (url == AppConstants.homeUrl) {
      notifier.setUrl(url);
      _clearCurrentMeshHost();
      setState(() => _activeRuntime.showHome = true);
      notifier.setLoading(false);
      notifier.setNavState(canGoBack: false, canGoForward: false);
      return;
    }

    if (url.startsWith(AppConstants.meshSchemePrefix)) {
      notifier.setAddressBar(url);
      await _openMeshUrl(url);
      return;
    }

    notifier.setUrl(url);
    _clearCurrentMeshHost();
    setState(() => _activeRuntime.showHome = false);
    await _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _openMeshUrl(String meshUrl) async {
    final canOpen = await _ensureMeshIdentity(meshUrl);
    if (!canOpen || !mounted) {
      ref.read(browserProvider.notifier).setLoading(false);
      return;
    }

    await _resolveMesh(meshUrl);
  }

  Future<bool> _ensureMeshIdentity(String pendingMeshUrl) async {
    final identityNotifier = ref.read(meshIdentityProvider.notifier);
    await identityNotifier.ensureLoaded();
    if (!mounted) {
      return false;
    }

    var identity = ref.read(meshIdentityProvider);
    if (identity.isMeshLoggedIn) {
      return true;
    }
    if (!mounted) {
      return false;
    }

    final canUseStoredIdentity =
        identity.handle != null &&
        identity.peerId != null &&
        identity.publicKey != null &&
        identity.privateKey != null;
    final action = await showModalBottomSheet<_MeshJoinAction>(
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
                'Join the Mesh',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: SaturnTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                pendingMeshUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.meshAccent,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Mesh identity is required before opening this site.',
                style: TextStyle(color: SaturnTheme.textSecondary),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () =>
                      Navigator.pop(context, _MeshJoinAction.create),
                  child: const Text('Create Identity'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: canUseStoredIdentity
                      ? () => Navigator.pop(context, _MeshJoinAction.login)
                      : null,
                  child: Text(
                    canUseStoredIdentity
                        ? 'Log In With ${identity.handle}'
                        : 'Log In With Existing Identity',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (action == _MeshJoinAction.create) {
      final created = await identityNotifier.createIdentity();
      if (!created && mounted) {
        _showMeshIdentityError(ref.read(meshIdentityProvider).errorMessage);
      }
      if (created && mounted) {
        _showMeshHome();
      }
      return false;
    }

    if (action == _MeshJoinAction.login) {
      final loggedIn = await identityNotifier.ensureRegistered();
      if (!loggedIn && mounted) {
        _showMeshIdentityError(ref.read(meshIdentityProvider).errorMessage);
      }
      if (loggedIn && mounted) {
        _showMeshHome();
      }
      return false;
    }

    return false;
  }

  void _showMeshHome() {
    _clearCurrentMeshHost();
    final notifier = ref.read(browserProvider.notifier);
    notifier.setUrl(AppConstants.homeUrl);
    notifier.setLoading(false);
    notifier.setNavState(canGoBack: false, canGoForward: false);
    setState(() => _activeRuntime.showHome = true);
  }

  void _showMeshIdentityError(String? message) {
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
                'Mesh unavailable',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: SaturnTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message ?? 'Mesh identity registration failed.',
                style: const TextStyle(color: SaturnTheme.textSecondary),
              ),
              const SizedBox(height: 18),
            ],
          ),
        );
      },
    );
  }

  Future<void> _resolveMesh(String meshUrl) async {
    final notifier = ref.read(browserProvider.notifier);
    notifier.setUrl(meshUrl);
    notifier.setLoading(true);
    setState(() => _activeRuntime.showHome = false);

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
    notifier.setUrl(displayUrl);
    notifier.setLoading(true);
    setState(() => _activeRuntime.showHome = false);

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
        notifier.setUrl(displayUrl);
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
    } else if (_activeRuntime.showHome) {
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

  void _clearCurrentMeshHost() {
    _currentHostPeerId = null;
    _currentMeshHandle = null;
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
}

class _BrowserMenuButton extends StatelessWidget {
  const _BrowserMenuButton({
    required this.canGoBack,
    required this.canGoForward,
    required this.isLoading,
    required this.onSelected,
  });

  final bool canGoBack;
  final bool canGoForward;
  final bool isLoading;
  final ValueChanged<_BrowserMenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_BrowserMenuAction>(
      tooltip: 'Menu',
      color: SaturnTheme.surface,
      icon: const Icon(Icons.menu, color: SaturnTheme.textSecondary),
      onSelected: onSelected,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _BrowserMenuAction.back,
          enabled: canGoBack,
          child: const _MenuItem(icon: Icons.arrow_back, label: 'Back'),
        ),
        PopupMenuItem(
          value: _BrowserMenuAction.forward,
          enabled: canGoForward,
          child: const _MenuItem(icon: Icons.arrow_forward, label: 'Forward'),
        ),
        PopupMenuItem(
          value: _BrowserMenuAction.reloadOrHome,
          child: _MenuItem(
            icon: isLoading ? Icons.close : Icons.refresh,
            label: isLoading ? 'Stop' : 'Reload / Home',
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _BrowserMenuAction.history,
          child: _MenuItem(icon: Icons.history, label: 'History'),
        ),
        const PopupMenuItem(
          value: _BrowserMenuAction.bookmarks,
          child: _MenuItem(icon: Icons.bookmarks_outlined, label: 'Bookmarks'),
        ),
        const PopupMenuItem(
          value: _BrowserMenuAction.downloads,
          child: _MenuItem(icon: Icons.download_outlined, label: 'Downloads'),
        ),
        const PopupMenuItem(
          value: _BrowserMenuAction.help,
          child: _MenuItem(icon: Icons.help_outline, label: 'Help'),
        ),
        const PopupMenuItem(
          value: _BrowserMenuAction.settings,
          child: _MenuItem(icon: Icons.settings_outlined, label: 'Settings'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _BrowserMenuAction.exit,
          child: _MenuItem(icon: Icons.exit_to_app, label: 'Exit'),
        ),
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: SaturnTheme.textSecondary, size: 20),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: SaturnTheme.textPrimary)),
      ],
    );
  }
}

enum _BrowserMenuAction {
  back('Back'),
  forward('Forward'),
  reloadOrHome('Reload / Home'),
  history('History'),
  bookmarks('Bookmarks'),
  downloads('Downloads'),
  help('Help'),
  settings('Settings'),
  exit('Exit');

  const _BrowserMenuAction(this.label);

  final String label;
}

class _TabListTile extends StatelessWidget {
  const _TabListTile({
    required this.tab,
    required this.active,
    required this.canClose,
    required this.onTap,
    required this.onClose,
  });

  final BrowserTab tab;
  final bool active;
  final bool canClose;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final title = tab.title.trim().isEmpty ? 'New tab' : tab.title;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: active ? SaturnTheme.surfaceAlt : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 58),
            padding: const EdgeInsets.only(left: 12, right: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active ? SaturnTheme.meshAccent : SaturnTheme.border,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  tab.isMeshPage ? Icons.hub_outlined : Icons.language,
                  color: tab.isMeshPage
                      ? SaturnTheme.meshAccent
                      : SaturnTheme.textSecondary,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SaturnTheme.mono.copyWith(
                          color: active
                              ? SaturnTheme.textPrimary
                              : SaturnTheme.textSecondary,
                          fontSize: 13,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        tab.addressBarText.isEmpty
                            ? 'New tab'
                            : tab.addressBarText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SaturnTheme.mono.copyWith(
                          color: SaturnTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (tab.isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (canClose)
                  IconButton(
                    tooltip: 'Close tab',
                    visualDensity: VisualDensity.compact,
                    splashRadius: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    onPressed: onClose,
                    icon: const Icon(
                      Icons.close,
                      color: SaturnTheme.textSecondary,
                      size: 15,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabRuntime {
  bool showHome = true;
  String? hostPeerId;
  String? meshHandle;
}

enum _MeshJoinAction { create, login }

class _PlaylistRewriteResult {
  const _PlaylistRewriteResult(this.value, {required this.changed});

  final Object? value;
  final bool changed;
}
