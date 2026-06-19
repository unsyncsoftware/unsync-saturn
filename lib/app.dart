import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants/app_constants.dart';
import 'core/theme/saturn_theme.dart';
import 'features/browser/presentation/browser_screen.dart';

class SaturnApp extends StatelessWidget {
  const SaturnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        title: AppConstants.appName,
        theme: SaturnTheme.dark,
        home: const BrowserScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
