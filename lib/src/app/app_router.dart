import 'package:app/src/app/app_home.dart';
import 'package:app/src/data/repository.dart';
import 'package:app/src/screens/git_repository.dart';
import 'package:app/src/screens/git_repository_edit.dart';
import 'package:app/src/screens/gpg_key.dart';
import 'package:app/src/screens/security_settings.dart';
import 'package:app/src/screens/settings.dart';
import 'package:app/src/screens/unlock.dart';
import 'package:app/src/screens/vault_detail.dart';
import 'package:app/src/screens/vault_list.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

abstract class AppRouter {
  static final routerConfig = GoRouter(
    initialLocation: '/vaults',
    navigatorKey: _rootNavigatorKey,
    refreshListenable: Repository.instance.lockStateListenable,
    redirect: (context, state) {
      final isLocked = Repository.instance.isLocked;
      final isUnlockRoute = state.matchedLocation == '/unlock';
      if (isLocked && !isUnlockRoute) {
        return '/unlock';
      }
      if (!isLocked && isUnlockRoute) {
        return '/vaults';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/unlock',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => MaterialPage(
          key: state.pageKey,
          child: const UnlockScreen(),
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppHome(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/vaults',
                pageBuilder: (context, state) => MaterialPage(
                  key: state.pageKey,
                  child: VaultListScreen(),
                ),
                routes: [
                  GoRoute(
                    path: '/:path(.*)',
                    pageBuilder: (context, state) => MaterialPage(
                      key: state.pageKey,
                      child: VaultDetailScreen(state.pathParameters["path"]!),
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) => MaterialPage(
                  key: state.pageKey,
                  child: SettingsScreen(),
                ),
                routes: [
                  GoRoute(
                    path: '/git-repository',
                    pageBuilder: (context, state) => MaterialPage(
                      key: state.pageKey,
                      child: GitRepositoryScreen(),
                    ),
                    routes: [
                      GoRoute(
                        path: '/edit',
                        parentNavigatorKey: _rootNavigatorKey,
                        pageBuilder: (context, state) => MaterialPage(
                          key: state.pageKey,
                          fullscreenDialog: true,
                          child: GitRepositoryEditScreen(),
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: '/gpg-key',
                    pageBuilder: (context, state) => MaterialPage(
                      key: state.pageKey,
                      child: GpgKeyScreen(),
                    ),
                  ),
                  GoRoute(
                    path: '/security',
                    pageBuilder: (context, state) => MaterialPage(
                      key: state.pageKey,
                      child: const SecuritySettingsScreen(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
