import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app/app_controller.dart';
import 'app/device_prefs.dart';
import 'platform/folder_access.dart';
import 'ui/home_shell.dart';
import 'ui/privacy.dart';
import 'ui/setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(
    prefs: await DevicePrefs.load(),
    privateDir: await getApplicationSupportDirectory(),
    network: http.Client(),
  );
  await controller.restore(reopenRecordFolder);
  runApp(AssetPortfolioApp(controller: controller));
}

class AssetPortfolioApp extends StatelessWidget {
  const AssetPortfolioApp({
    super.key,
    required this.controller,
    this.pick = pickRecordFolder,
  });

  final AppController controller;
  final Future<PickedFolder?> Function() pick;

  @override
  // Rebuilt on controller changes so the theme choice applies at once.
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => MaterialApp(
      title: 'Portfolio Tracker',
      // Above the Navigator, so dialogs and pushed routes are masked too.
      builder: (_, child) => ListenableBuilder(
        listenable: controller,
        builder: (_, _) =>
            PrivacyScope(masked: controller.privacyMode, child: child!),
      ),
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: controller.prefs.themeMode,
      home: ListenableBuilder(
        listenable: controller,
        builder: (_, _) =>
            controller.scan?.descriptor != null && !controller.folderAccessLost
            ? HomeShell(controller: controller, pick: pick)
            : SetupScreen(controller: controller, pick: pick),
      ),
    ),
  );
}
