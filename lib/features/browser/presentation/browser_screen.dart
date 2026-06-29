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
                        _BrowserMenuButton(onSelected: _handleMenuAction),
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
      case _BrowserMenuAction.newTab:
        _newTab();
      case _BrowserMenuAction.bookmarks:
        _showPlaceholderSheet(action.label);
      case _BrowserMenuAction.history:
        _showPlaceholderSheet(action.label);
      case _BrowserMenuAction.downloads:
        _showPlaceholderSheet(action.label);
      case _BrowserMenuAction.meshIdentity:
        _showMeshIdentitySheet();
      case _BrowserMenuAction.discoverMeshSites:
        _showComingSoon(action.label);
      case _BrowserMenuAction.settings:
        _showComingSoon(action.label);
      case _BrowserMenuAction.aboutSaturn:
        _showAboutSaturnSheet();
    }
  }

  void _showComingSoon(String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label coming soon'),
        backgroundColor: SaturnTheme.surfaceAlt,
        behavior: SnackBarBehavior.floating,
      ),
    );
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

  void _showMeshIdentitySheet() {
    final identity = ref.read(meshIdentityProvider);
    final handle = identity.isMeshLoggedIn && identity.handle != null
        ? identity.handle!
        : 'GUEST';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SaturnTheme.voidBg,
      barrierColor: Colors.black54,
      shape: const BeveledRectangleBorder(),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mesh identity',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: SaturnTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                _MeshIdentityMenuBadge(label: handle),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAboutSaturnSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SaturnTheme.voidBg,
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
                  'About Saturn',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: SaturnTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                FutureBuilder<String>(
                  future: _loadSaturnAppVersion(),
                  builder: (context, snapshot) {
                    final version = snapshot.data ?? 'loading...';
                    return Text(
                      'Version $version',
                      style: SaturnTheme.mono.copyWith(
                        color: SaturnTheme.meshAccent,
                        fontSize: 13,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<String> _loadSaturnAppVersion() async {
    try {
      final pubspec = await rootBundle.loadString('pubspec.yaml');
      for (final line in const LineSplitter().convert(pubspec)) {
        final trimmed = line.trim();
        if (trimmed.startsWith('version:')) {
          return trimmed.substring('version:'.length).trim();
        }
      }
    } catch (_) {}
    return 'unknown';
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
      backgroundColor: SaturnTheme.voidBg,
      barrierColor: Colors.black54,
      shape: const BeveledRectangleBorder(),
      builder: (context) {
        var primaryLoading = false;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final primaryLabel = canUseStoredIdentity
                ? 'Log In as ${identity.handle}'
                : 'Create Identity';

            Future<void> runPrimaryAction() async {
              if (primaryLoading) {
                return;
              }

              if (canUseStoredIdentity) {
                setSheetState(() => primaryLoading = true);
                final loggedIn = await identityNotifier.ensureRegistered();
                if (!context.mounted) {
                  return;
                }
                Navigator.pop(
                  context,
                  loggedIn ? _MeshJoinAction.login : _MeshJoinAction.failed,
                );
                return;
              }

              final choice = await _showCreateIdentityHandlePrompt();
              if (choice == null || !context.mounted) {
                return;
              }

              setSheetState(() => primaryLoading = true);
              final created = await identityNotifier.createIdentity(
                handle: choice.handle,
              );
              if (!context.mounted) {
                return;
              }
              Navigator.pop(
                context,
                created ? _MeshJoinAction.create : _MeshJoinAction.failed,
              );
            }

            return SafeArea(
              child: Padding(
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
                        color: SaturnTheme.accent,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Mesh identity is required before opening this site.',
                      style: TextStyle(color: SaturnTheme.textSecondary),
                    ),
                    const SizedBox(height: 18),
                    _MeshJoinPrimaryButton(
                      label: primaryLabel,
                      loading: primaryLoading,
                      onTap: runPrimaryAction,
                    ),
                    const SizedBox(height: 10),
                    _MeshJoinSecondaryButton(
                      label: 'Login as Guest',
                      onTap: primaryLoading
                          ? null
                          : () => Navigator.pop(context, _MeshJoinAction.guest),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          shape: const BeveledRectangleBorder(),
                        ),
                        onPressed: primaryLoading
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('Cancel'),
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

    if (action == _MeshJoinAction.create) {
      return mounted;
    }

    if (action == _MeshJoinAction.login) {
      if (mounted) {
        _showMeshHome();
      }
      return false;
    }

    if (action == _MeshJoinAction.failed) {
      if (mounted) {
        _showMeshIdentityError(ref.read(meshIdentityProvider).errorMessage);
      }
      return false;
    }

    if (action == _MeshJoinAction.guest) {
      return true;
    }

    return false;
  }

  Future<_MeshCreateIdentityChoice?> _showCreateIdentityHandlePrompt() async {
    final controller = TextEditingController();
    String? errorText;

    final choice = await showModalBottomSheet<_MeshCreateIdentityChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SaturnTheme.surface,
      barrierColor: Colors.black54,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void submit() {
              final handle = controller.text.trim();
              if (handle.isEmpty) {
                setSheetState(() {
                  errorText = 'Enter a handle or use a random one.';
                });
                return;
              }

              Navigator.pop(context, _MeshCreateIdentityChoice(handle: handle));
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  20,
                  20,
                  20 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Create Identity',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: SaturnTheme.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Choose a mesh handle.',
                      style: TextStyle(color: SaturnTheme.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp('[A-Za-z0-9_-]'),
                        ),
                      ],
                      style: SaturnTheme.mono.copyWith(
                        color: SaturnTheme.textPrimary,
                        fontSize: 14,
                      ),
                      cursorColor: SaturnTheme.meshAccent,
                      decoration: InputDecoration(
                        prefixText: '@',
                        hintText: 'your-handle',
                        errorText: errorText,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: SaturnTheme.border,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: SaturnTheme.meshAccent,
                            width: 1.4,
                          ),
                        ),
                      ),
                      onChanged: (_) {
                        if (errorText != null) {
                          setSheetState(() => errorText = null);
                        }
                      },
                      onSubmitted: (_) => submit(),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: submit,
                        child: const Text('Continue'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => Navigator.pop(
                          context,
                          const _MeshCreateIdentityChoice(),
                        ),
                        child: const Text('Use random handle'),
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

    controller.dispose();
    return choice;
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

  // ignore: unused_element
  Future<void> _goBack() async {
    if (await _webViewController?.canGoBack() ?? false) {
      await _webViewController?.goBack();
    }
  }

  // ignore: unused_element
  Future<void> _goForward() async {
    if (await _webViewController?.canGoForward() ?? false) {
      await _webViewController?.goForward();
    }
  }

  // ignore: unused_element
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

class _BrowserMenuButton extends ConsumerWidget {
  const _BrowserMenuButton({required this.onSelected});

  final ValueChanged<_BrowserMenuAction> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(meshIdentityProvider);
    final identityLabel = identity.isMeshLoggedIn && identity.handle != null
        ? identity.handle!
        : 'GUEST';

    return IconButton(
      tooltip: 'Menu',
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
      icon: const Icon(Icons.menu, color: SaturnTheme.textSecondary),
      onPressed: () {
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: SaturnTheme.voidBg,
          barrierColor: Colors.black54,
          builder: (context) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MenuSection(
                      label: 'BROWSER',
                      children: [
                        _MenuItem(
                          icon: Icons.add,
                          label: 'New tab',
                          onTap: () => onSelected(_BrowserMenuAction.newTab),
                        ),
                        _MenuItem(
                          icon: Icons.bookmarks_outlined,
                          label: 'Bookmarks',
                          onTap: () => onSelected(_BrowserMenuAction.bookmarks),
                        ),
                        _MenuItem(
                          icon: Icons.history,
                          label: 'History',
                          onTap: () => onSelected(_BrowserMenuAction.history),
                        ),
                        _MenuItem(
                          icon: Icons.download_outlined,
                          label: 'Downloads',
                          onTap: () => onSelected(_BrowserMenuAction.downloads),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _MenuSection(
                      label: 'MESH',
                      children: [
                        _MenuItem(
                          icon: Icons.hub_outlined,
                          label: 'Mesh identity',
                          trailing: _MeshIdentityMenuBadge(
                            label: identityLabel,
                          ),
                          onTap: () =>
                              onSelected(_BrowserMenuAction.meshIdentity),
                        ),
                        _MenuItem(
                          icon: Icons.travel_explore,
                          label: 'Discover mesh sites',
                          onTap: () =>
                              onSelected(_BrowserMenuAction.discoverMeshSites),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _MenuSection(
                      label: 'APP',
                      children: [
                        _MenuItem(
                          icon: Icons.settings_outlined,
                          label: 'Settings',
                          onTap: () => onSelected(_BrowserMenuAction.settings),
                        ),
                        _MenuItem(
                          icon: Icons.info_outline,
                          label: 'About Saturn',
                          onTap: () =>
                              onSelected(_BrowserMenuAction.aboutSaturn),
                        ),
                      ],
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
}

class _MenuSection extends StatelessWidget {
  const _MenuSection({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: SaturnTheme.mono.copyWith(
            color: SaturnTheme.meshAccent,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: SaturnTheme.textSecondary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: SaturnTheme.textPrimary),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      ),
    );
  }
}

class _MeshIdentityMenuBadge extends StatelessWidget {
  const _MeshIdentityMenuBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(color: SaturnTheme.meshAccent),
        color: SaturnTheme.surfaceAlt,
      ),
      child: Text(
        label,
        style: SaturnTheme.mono.copyWith(
          color: SaturnTheme.meshAccent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

enum _BrowserMenuAction {
  newTab('New tab'),
  history('History'),
  bookmarks('Bookmarks'),
  downloads('Downloads'),
  meshIdentity('Mesh identity'),
  discoverMeshSites('Discover mesh sites'),
  settings('Settings'),
  aboutSaturn('About Saturn');

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

class _MeshJoinPrimaryButton extends StatelessWidget {
  const _MeshJoinPrimaryButton({
    required this.label,
    required this.loading,
    required this.onTap,
  });

  final String label;
  final bool loading;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        color: loading ? SaturnTheme.textMuted : SaturnTheme.accent,
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: SaturnTheme.voidBg,
                    strokeWidth: 2,
                  ),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    color: SaturnTheme.voidBg,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}

class _MeshJoinSecondaryButton extends StatelessWidget {
  const _MeshJoinSecondaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: SaturnTheme.border),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: SaturnTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

enum _MeshJoinAction { create, login, guest, failed }

class _MeshCreateIdentityChoice {
  const _MeshCreateIdentityChoice({this.handle});

  final String? handle;
}

class _PlaylistRewriteResult {
  const _PlaylistRewriteResult(this.value, {required this.changed});

  final Object? value;
  final bool changed;
}
