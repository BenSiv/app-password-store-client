import 'package:app/src/data/models.dart';
import 'package:app/src/data/repository.dart';
import 'package:app/src/utils/form_field_validators.dart';
import 'package:app/src/utils/platform_security.dart';
import 'package:app/src/utils/show_error_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

final class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  bool _loading = true;
  bool _hasGpgKey = false;
  bool _hasEncryptedKey = false;
  BiometricStatus _biometricStatus = BiometricStatus.unavailable;

  @override
  void initState() {
    super.initState();
    _refreshCapabilities();
  }

  Future<void> _refreshCapabilities() async {
    final hasKey = await Repository.instance.hasGpgKey();
    final hasEncrypted = await Repository.instance.hasEncryptedGpgKey();
    final bioStatus = await PlatformSecurity.getBiometricStatus();
    if (!mounted) return;
    setState(() {
      _hasGpgKey = hasKey;
      _hasEncryptedKey = hasEncrypted;
      _biometricStatus = bioStatus;
      _loading = false;
    });
  }

  Future<void> _selectMode(AppLockMode targetMode) async {
    if (targetMode == Repository.instance.appLockMode) {
      return;
    }

    if (!_hasGpgKey) {
      showErrorDialog(context, 'Import a GPG private key first before configuring App Lock.');
      return;
    }

    if (targetMode != AppLockMode.off && !_hasEncryptedKey) {
      showErrorDialog(
        context,
        'Your imported GPG private key has no passphrase. Import a passphrase-protected GPG key so your GPG passphrase can act as the Master Password.',
      );
      return;
    }

    if (targetMode == AppLockMode.biometric && _biometricStatus != BiometricStatus.available) {
      showErrorDialog(context, _biometricStatusDescription(_biometricStatus));
      return;
    }

    final applied = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ConfirmPassphraseForModeDialog(targetMode: targetMode),
    );

    if (applied == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('App Lock updated to ${targetMode.label}')),
      );
      await _refreshCapabilities();
    }
  }

  String _biometricStatusDescription(BiometricStatus status) {
    switch (status) {
      case BiometricStatus.available:
        return 'Hardware-backed Strong Biometrics (Class 3) with GPG passphrase fallback.';
      case BiometricStatus.noneEnrolled:
        return 'No strong biometric enrolled on this device. Enroll a Class 3 fingerprint/face in system settings first.';
      case BiometricStatus.noHardware:
        return 'Strong (Class 3) biometric hardware is not available on this device.';
      case BiometricStatus.unavailable:
        return 'Strong biometrics are currently unavailable on this device.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Lock & Security'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListenableBuilder(
                listenable: Repository.instance.lockStateListenable,
                builder: (context, _) {
                  final currentMode = Repository.instance.appLockMode;
                  final canEnableLock = _hasGpgKey && _hasEncryptedKey;
                  final canEnableBiometric =
                      canEnableLock && _biometricStatus == BiometricStatus.available;

                  return ListView(
                    children: [
                      if (!_hasGpgKey)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Text(
                            'Import a passphrase-protected GPG key in Settings → GPG Key to enable App Lock.',
                            style: TextStyle(color: ColorScheme.of(context).error),
                          ),
                        )
                      else if (!_hasEncryptedKey)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Text(
                            'Your imported GPG key is unencrypted. Import a passphrase-protected GPG key to use your GPG passphrase as Master Password.',
                            style: TextStyle(color: ColorScheme.of(context).error),
                          ),
                        ),
                      RadioGroup<AppLockMode>(
                        groupValue: currentMode,
                        onChanged: (value) {
                          if (value != null) {
                            _selectMode(value);
                          }
                        },
                        child: Column(
                          children: [
                            RadioListTile<AppLockMode>(
                              value: AppLockMode.off,
                              title: const Text('Off'),
                              subtitle: const Text(
                                'Keep GPG passphrase in OS secure storage so vaults open automatically.',
                              ),
                            ),
                            RadioListTile<AppLockMode>(
                              value: AppLockMode.masterPassword,
                              enabled: canEnableLock,
                              title: const Text('GPG Passphrase (Master Password)'),
                              subtitle: const Text(
                                'Never store plaintext GPG passphrase on disk. Require passphrase on launch and immediately after backgrounding.',
                              ),
                            ),
                            RadioListTile<AppLockMode>(
                              value: AppLockMode.biometric,
                              enabled: canEnableBiometric,
                              title: const Text('Strong Biometrics + GPG Passphrase'),
                              subtitle: Text(_biometricStatusDescription(_biometricStatus)),
                            ),
                          ],
                        ),
                      ),
                      const Divider(),
                      const ListTile(
                        leading: Icon(Icons.timer_outlined),
                        title: Text('Auto-Lock Policy'),
                        subtitle: Text('Immediate when app is backgrounded or screen turns off'),
                      ),
                      const ListTile(
                        leading: Icon(Icons.content_paste_off_outlined),
                        title: Text('Clipboard Protection'),
                        subtitle: Text(
                          'Sensitive clipboard masking enabled; copied secrets auto-clear after 45 seconds',
                        ),
                      ),
                      const ListTile(
                        leading: Icon(Icons.screenshot_monitor_outlined),
                        title: Text('Screen Capture Protection'),
                        subtitle: Text(
                          'Screenshots and app-switcher previews are blocked (FLAG_SECURE)',
                        ),
                      ),
                      if (currentMode != AppLockMode.off) ...[
                        const Divider(),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: OutlinedButton.icon(
                            onPressed: () => Repository.instance.lock(),
                            icon: const Icon(Icons.lock_outline),
                            label: const Text('Lock Vault Now'),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
      ),
    );
  }
}

final class _ConfirmPassphraseForModeDialog extends StatefulWidget {
  const _ConfirmPassphraseForModeDialog({required this.targetMode});

  final AppLockMode targetMode;

  @override
  State<_ConfirmPassphraseForModeDialog> createState() => _ConfirmPassphraseForModeDialogState();
}

final class _ConfirmPassphraseForModeDialogState extends State<_ConfirmPassphraseForModeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passphraseController = TextEditingController();
  var _autovalidateMode = AutovalidateMode.disabled;
  bool _obscured = true;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _handleConfirm() async {
    if (_submitting) return;
    if (_autovalidateMode != AutovalidateMode.onUserInteraction) {
      setState(() => _autovalidateMode = AutovalidateMode.onUserInteraction);
    }
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await Repository.instance.setAppLockMode(
        widget.targetMode,
        passphrase: _passphraseController.text,
      );
      _passphraseController.clear();
      if (!mounted) return;
      Navigator.pop(context, true);
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'BIOMETRIC_CANCELED') {
        setState(() => _errorMessage = 'Biometric confirmation was canceled');
      } else {
        setState(() => _errorMessage = e.message ?? 'Biometric setup failed');
      }
      _formKey.currentState?.validate();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = '$e');
      _formKey.currentState?.validate();
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final description = widget.targetMode == AppLockMode.biometric
        ? 'Enter your GPG passphrase, then confirm strong biometrics to wrap it in hardware secure storage:'
        : 'Confirm your GPG passphrase to update App Lock settings:';

    return AlertDialog(
      title: const Text('Confirm GPG Passphrase'),
      content: Form(
        key: _formKey,
        autovalidateMode: _autovalidateMode,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(description),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passphraseController,
              obscureText: _obscured,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _handleConfirm(),
              decoration: InputDecoration(
                labelText: 'GPG Passphrase',
                helperText: '',
                suffixIcon: IconButton(
                  icon: Icon(_obscured ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscured = !_obscured),
                ),
              ),
              validator: (value) {
                return FormFieldValidators.isRequired(value) ?? _errorMessage;
              },
              onChanged: (_) {
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
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: _submitting ? null : _handleConfirm,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('CONFIRM'),
        ),
      ],
    );
  }
}
