import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../resolver/mesh_resolver.dart';
import '../services/mesh_client.dart';

final meshResolverProvider = Provider<MeshResolver>((ref) => MeshResolver());

final meshClientProvider = Provider<MeshClient>((ref) {
  final client = MeshClient();
  ref.onDispose(client.dispose);
  return client;
});

final meshResolveProvider = FutureProvider.autoDispose
    .family<MeshResolveResult, String>((ref, url) {
      return ref.watch(meshResolverProvider).resolve(url);
    });
