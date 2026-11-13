import 'package:app/src/app/app_router.dart';
import 'package:app/src/app/app_theme.dart';
import 'package:app/src/data/repository.dart';
import 'package:flutter/material.dart';

final class App extends StatefulWidget {
  @override
  State<App> createState() => _AppState();
}

final class _AppState extends State<App> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onHide: Repository.instance.onAppBackgrounded,
      onPause: Repository.instance.onAppBackgrounded,
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      routerConfig: AppRouter.routerConfig,
      theme: AppTheme.theme,
      darkTheme: AppTheme.darkTheme,
    );
  }
}
