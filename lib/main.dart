// main.dart - khung app: thanh điều hướng 4 tab (Chat, Lịch sử, Model, Cài đặt); màn rộng (Windows/tablet) dùng NavigationRail.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screens/chat_screen.dart';
import 'screens/history_screen.dart';
import 'screens/models_screen.dart';
import 'screens/settings_screen.dart';
import 'services/background_guard.dart';
import 'services/update_service.dart';
import 'state.dart';
import 'widgets/legal_gate.dart';
import 'widgets/update_banner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  app = await AppState.create();
  await BackgroundGuard.init();
  runApp(const YuiApp());
}

ThemeData _theme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF), brightness: b),
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );

class YuiApp extends StatelessWidget {
  const YuiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) => MaterialApp(
        title: 'Yui',
        debugShowCheckedModeBanner: false,
        themeMode: app.settings.themeMode,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        builder: (context, child) => ListenableBuilder(
          listenable: updater,
          builder: (context, _) {
            final show = updater.state != UpdateState.idle;
            return Column(children: [
              if (show) const SafeArea(bottom: false, child: UpdateBanner()),
              Expanded(child: show ? MediaQuery.removePadding(context: context, removeTop: true, child: child!) : child!),
            ]);
          },
        ),
        home: const LegalGate(child: HomeShell()),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _titles = ['Chat', 'Lịch sử', 'Model', 'Cài đặt'];
  static const _icons = [Icons.chat_bubble_outline, Icons.history, Icons.memory, Icons.settings_outlined];
  static const _iconsOn = [Icons.chat_bubble, Icons.history, Icons.memory, Icons.settings];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final u = await app.maybeCheckUpdate();
      if (u != null && mounted) _showUpdate(u);
    });
  }

  void _showUpdate(UpdateInfo u) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Có bản mới ${u.version}'),
        content: Text(u.notes.trim().isEmpty
            ? 'Tải bản mới rồi mở file để cài đè lên app hiện tại, dữ liệu và model của bạn được giữ nguyên.'
            : u.notes),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Để sau')),
          TextButton(
            onPressed: () {
              launchUrl(Uri.parse(u.url), mode: LaunchMode.externalApplication);
              Navigator.pop(ctx);
            },
            child: const Text('Mở trang tải'),
          ),
          if (u.assetUrl != null)
            FilledButton(
              onPressed: () {
                updater.start(u.assetUrl!, u.assetName ?? 'Yui-update', u.assetSize); // tải ngầm, có thanh tiến độ
                Navigator.pop(ctx);
              },
              child: const Text('Tải ngầm'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const pages = [ChatScreen(), HistoryScreen(), ModelsScreen(), SettingsScreen()];
    return ValueListenableBuilder<int>(
      valueListenable: app.tab,
      builder: (context, tab, _) {
        final wide = MediaQuery.of(context).size.width >= 800;
        final body = IndexedStack(index: tab, children: pages);
        if (wide) {
          return Scaffold(
            body: Row(children: [
              NavigationRail(
                selectedIndex: tab,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => app.tab.value = i,
                destinations: [
                  for (var i = 0; i < 4; i++)
                    NavigationRailDestination(
                      icon: Icon(_icons[i]),
                      selectedIcon: Icon(_iconsOn[i]),
                      label: Text(_titles[i]),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ]),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => app.tab.value = i,
            destinations: [
              for (var i = 0; i < 4; i++)
                NavigationDestination(
                  icon: Icon(_icons[i]),
                  selectedIcon: Icon(_iconsOn[i]),
                  label: _titles[i],
                ),
            ],
          ),
        );
      },
    );
  }
}
