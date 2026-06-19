import 'package:flutter_test/flutter_test.dart';
import 'package:unsync_saturn/app.dart';
import 'package:unsync_saturn/core/constants/app_constants.dart';
import 'package:unsync_saturn/features/browser/presentation/browser_screen.dart';
import 'package:unsync_saturn/features/mesh/resolver/mesh_resolver.dart';

void main() {
  test('Saturn app wiring compiles', () {
    expect(AppConstants.appName, 'Saturn');
    expect(AppConstants.packageId, 'uk.unsync.saturn');
    expect(SaturnApp, isA<Type>());
    expect(BrowserScreen, isA<Type>());
    expect(MeshResolveStatus.success.name, 'success');
  });
}
