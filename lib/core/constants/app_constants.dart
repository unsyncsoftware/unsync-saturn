class AppConstants {
  const AppConstants._();

  static const meshScheme = 'mesh';
  static const meshSchemePrefix = 'mesh://';
  static const registryBase = 'https://mesh.unsync.uk';
  static const resolveEndpoint = 'https://mesh.unsync.uk/mesh/resolve';
  static const signalBase = 'wss://signal.unsync.uk';
  static const relayBase = 'wss://relay.unsync.uk';
  static const appName = 'Saturn';
  static const appTagline = 'Internet & Private Network Browser';
  static const packageId = 'uk.unsync.saturn';
  static const homeUrl = 'about:saturn';
  static const fallbackSearch = 'https://search.brave.com/search?q=';
  static const resolveTimeout = Duration(seconds: 10);
  static const connectTimeout = Duration(seconds: 15);
}
