import 'package:app/src/data/repository.dart';
import 'package:app/src/utils/show_error_dialog.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher_string.dart';

final class SettingsScreen extends StatefulWidget {
  @override
  State<StatefulWidget> createState() {
    return _SettingsScreenState();
  }
}

final class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _handleResetApp() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => _ResetAppConfirmDialog(),
    );

    if (result != true) {
      return;
    }

    try {
      await Repository.instance.eraseAllData();
    } catch (e) {
      showErrorDialog(context, '$e');
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('App reset successfully'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings'),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            ListTile(
              title: Text('Git Repository'),
              onTap: () => context.go('/settings/git-repository'),
            ),
            ListTile(
              title: Text('GPG Key'),
              onTap: () => context.go('/settings/gpg-key'),
            ),
            ListTile(
              title: Text('Privacy Policy'),
              onTap: () => launchUrlString('https://docs.google.com/document/d/e/2PACX-1vRTCnm5Ry2T1MAh8EK8ge0QH4eByt6MjQzJf6Ixdg9SqTl5cjqpu44Di1cM1-NUtTN7_vSNvJ1KFL8v/pub'),
            ),
            ListTile(
              title: Text('Reset App'),
              textColor: ColorScheme.of(context).error,
              onTap: _handleResetApp,
            ),
          ],
        ),
      ),
    );
  }
}

final class _ResetAppConfirmDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reset App'),
      content: Text(
        'This action will delete the following data from your device and restore the app to its default state:\n\n'
        '- Git Repository\n'
        '- GPG Key',
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: ColorScheme.of(context).onSurface.withValues(alpha: 0.58)),
          child: Text('CANCEL'),
          onPressed: () => Navigator.pop(context),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: ColorScheme.of(context).error),
          child: Text('RESET'),
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
