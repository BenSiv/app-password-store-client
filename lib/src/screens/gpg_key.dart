import 'package:app/src/data/repository.dart';
import 'package:app/src/utils/form_field_validators.dart';
import 'package:app/src/utils/logger.dart';
import 'package:app/src/utils/show_error_dialog.dart';
import 'package:dart_pg/dart_pg.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

final class GpgKeyScreen extends StatefulWidget {
  @override
  State<StatefulWidget> createState() {
    return _GpgKeyScreenState();
  }
}

final class _GpgKeyScreenState extends State<GpgKeyScreen> {
  Future<void> _handleImport() async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => _SelectImportMethodDialog(),
    );

    late final String armored;

    switch (value) {
      case 'file':
        final result = await FilePicker.platform.pickFiles();
        if (result == null) return;
        try {
          armored = await result.xFiles.first.readAsString();
        } catch (e) {
          showErrorDialog(context, '$e');
          return;
        }
      case 'clipboard':
        final result = await Clipboard.getData('text/plain');
        if (result == null) return;
        armored = result.text!;
      case null:
        return;
      default:
        throw 'Unknown value: $value.';
    }

    try {
      await Repository.instance.saveGpgPrivateKey(armored: armored);
    } catch (e) {
      if (e == 'Passphrase required') {
        final result = await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => _EnterPassphraseDialog(armored: armored),
        );
        if (result == null) {
          // user canceled
          return;
        }
      } else {
        showErrorDialog(context, '$e');
        return;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('GPG key imported successfully'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('GPG Key'),
        actions: [
          PopupMenuButton<String>(
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'import',
                child: Text('Import'),
              ),
            ],
            onSelected: (value) {
              switch (value) {
                case 'import':
                  _handleImport();
                default:
                  throw 'Unknown value: $value';
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: StreamBuilder<PrivateKey>(
          stream: Repository.instance.subscribeGpgPrivateKey(),
          builder: (context, ss) {
            if (ss.hasError) return Center(child: Text('${ss.error}'));
            final privateKey = ss.data;
            if (privateKey == null) return SizedBox();
            return ListView(
              children: [
                ListTile(
                  title: Text('Key ID'),
                  subtitle: Text(privateKey.keyID.map((e) => e.toRadixString(16).padLeft(2, '0')).join().toUpperCase()),
                ),
                ListTile(
                  title: Text('Fingerprint'),
                  subtitle: Text(privateKey.fingerprint.map((e) => e.toRadixString(16).padLeft(2, '0')).join().toUpperCase()),
                ),
                ListTile(
                  title: Text('Identifiers'),
                  subtitle: Text(privateKey.users.map((e) => e.userID).join(' / ')),
                ),
                /* TODO: convert keyAlgorithm to string
                ListTile(
                  title: Text('Key Algorithm'),
                  subtitle: Text('${privateKey.keyAlgorithm}'),
                ),
                */
                ListTile(
                  title: Text('Key Strength'),
                  subtitle: Text('${privateKey.keyStrength}'),
                ),
                ListTile(
                  title: Text('Encrypted'),
                  subtitle: Text('${privateKey.isEncrypted}'),
                ),
                ListTile(
                  title: Text('Creation Time'),
                  subtitle: Text(privateKey.creationTime.toString().split('.').first),
                ),
                ListTile(
                  title: Text('Expiration Time'),
                  subtitle: Text(_getExpirationTime(privateKey)?.toString().split('.').first ?? 'none'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// `PrivateKey.expirationTime` seems to be null, so use the earliest expirationTime among the subkeys instead.
DateTime? _getExpirationTime(PrivateKey privateKey) {
  if (privateKey.expirationTime != null) {
    return privateKey.expirationTime;
  }

  final expirationTimes = privateKey.subkeys.map((e) => e.expirationTime).whereType<DateTime>();
  if (expirationTimes.isEmpty) {
    return null;
  }

  return expirationTimes.reduce((a, b) => a.isBefore(b) ? a : b);
}

final class _SelectImportMethodDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      children: [
        ListTile(
          title: Text('Select Import Method'),
          titleTextStyle: Theme.of(context).textTheme.titleLarge,
          subtitle: Text('Import ASCII-armored GPG private key.'),
        ),
        Divider(height: 1),
        ListTile(
          title: Text('Pick a file'),
          subtitle: Text('Pick a file from local or cloud storage.'),
          onTap: () => context.pop('file'),
        ),
        /* TODO: import GPG key via QR code scanning
        ListTile(
          title: Text('Scan QR Code'),
          subtitle: Text('Scan one or more QR codes in order.'),
          onTap: () => context.pop('qr_code'),
        ),
        */
        ListTile(
          title: Text('Paste from Clipboard'),
          subtitle: Text('Paste the current text of the clipboard.'),
          onTap: () => context.pop('clipboard'),
        ),
      ],
    );
  }
}

final class _EnterPassphraseDialog extends StatefulWidget {
  const _EnterPassphraseDialog({required this.armored});

  final String armored;

  @override
  State<StatefulWidget> createState() {
    return _EnterPassphraseDialogState();
  }
}

final class _EnterPassphraseDialogState extends State<_EnterPassphraseDialog> {
  final _formKey = GlobalKey<FormState>();
  var _autovalidateMode = AutovalidateMode.disabled;
  final _passphraseController = TextEditingController();
  String? _errorMessage;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _handleEnter() async {
    if (_autovalidateMode != AutovalidateMode.onUserInteraction) {
      setState(() => _autovalidateMode = AutovalidateMode.onUserInteraction);
    }
    if (!_formKey.currentState!.validate()) {
      logger.info('Form invalid');
      return;
    }
    try {
      await Repository.instance.saveGpgPrivateKey(
        armored: widget.armored,
        passphrase: _passphraseController.text,
      );
    } catch (e) {
      setState(() => _errorMessage = '$e');
      rethrow;
    }
    context.pop(Object());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Enter Passphrase'),
      content: Form(
        key: _formKey,
        autovalidateMode: _autovalidateMode,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('This key is encrypted. Please enter the passphrase:'),
            SizedBox(height: 12),
            TextFormField(
              controller: _passphraseController,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                helperText: '',
              ),
              validator: (value) {
                return FormFieldValidators.isRequired(value) ?? _errorMessage;
              },
              onChanged: (value) {
                if (_errorMessage != null) {
                  setState(() => _errorMessage = null);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          child: Text('CANCEL'),
          onPressed: () => context.pop(),
        ),
        TextButton(
          child: Text('ENTER'),
          onPressed: () => _handleEnter(),
        ),
      ],
    );
  }
}
