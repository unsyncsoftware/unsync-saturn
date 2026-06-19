import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../resolver/mesh_resolver.dart';

final meshResolverProvider = Provider<MeshResolver>((ref) => MeshResolver());

final meshResolveProvider = FutureProvider.autoDispose
    .family<MeshResolveResult, String>((ref, url) {
      return ref.watch(meshResolverProvider).resolve(url);
    });
