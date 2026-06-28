import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../resolver/mesh_resolver.dart';
import '../services/mesh_client.dart';
import '../services/mesh_identity_service.dart';
import '../services/mesh_search_service.dart';

final meshResolverProvider = Provider<MeshResolver>((ref) => MeshResolver());

final meshClientProvider = Provider<MeshClient>((ref) {
  final client = MeshClient();
  ref.listen<MeshIdentityState>(meshIdentityProvider, (_, next) {
    client.setIdentity(
      handle: next.isMeshLoggedIn ? next.handle : null,
      peerId: next.isMeshLoggedIn ? next.peerId : null,
    );
  }, fireImmediately: true);
  ref.onDispose(client.dispose);
  return client;
});

final meshIdentityProvider =
    StateNotifierProvider<MeshIdentityService, MeshIdentityState>(
      (ref) => MeshIdentityService(),
    );

final isMeshLoggedInProvider = Provider<bool>(
  (ref) => ref.watch(meshIdentityProvider).isMeshLoggedIn,
);

final currentHandleProvider = Provider<String?>(
  (ref) => ref.watch(meshIdentityProvider).handle,
);

final meshSearchServiceProvider = Provider<MeshSearchService>(
  (ref) => MeshSearchService(),
);

final meshSearchProvider = FutureProvider.autoDispose
    .family<List<MeshSearchResult>, String>((ref, query) {
      return ref.watch(meshSearchServiceProvider).search(query);
    });

final meshResolveProvider = FutureProvider.autoDispose
    .family<MeshResolveResult, String>((ref, url) {
      return ref.watch(meshResolverProvider).resolve(url);
    });
