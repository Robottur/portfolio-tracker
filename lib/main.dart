import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app/app_controller.dart';
import 'app/device_prefs.dart';
import 'platform/folder_access.dart';
import 'ui/home_shell.dart';
import 'ui/setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(
    prefs: await DevicePrefs.load(),
    privateDir: await getApplicationSupportDirectory(),
    network: http.Client(),
  );
  final saved = controller.prefs.folderLocation;
  if (saved != null) {
    final folder = await reopenRecordFolder(saved);
    try {
      if (folder == null) throw StateError('Folder could not be read');
      await controller.openFolder(folder, saved);
    } on Object {
      controller.markFolderUnavailable();
    }
  }
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
  Widget build(BuildContext context) => MaterialApp(
    title: 'Asset Portfolio',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: ListenableBuilder(
      listenable: controller,
      builder: (_, _) =>
          controller.scan?.descriptor != null && !controller.folderAccessLost
          ? HomeShell(controller: controller)
          : SetupScreen(controller: controller, pick: pick),
    ),
  );
}
