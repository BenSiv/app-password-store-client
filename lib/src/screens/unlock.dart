import 'package:app/src/data/models.dart';
import 'package:app/src/data/repository.dart';
import 'package:app/src/utils/form_field_validators.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

final class _UnlockScreenState extends State<UnlockScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passphraseController = TextEditingController();
  final _passphraseFocusNode = FocusNode();
  late final AppLifecycleListener _lifecycleListener;

  var _autovalidateMode = AutovalidateMode.disabled;
  bool _obscured = true;
  bool _submitting = false;
  bool _biometricInProgress = false;
  bool _promptedForCurrentForegroundSession = false;
  String? _errorMessage;
  String? _infoBanner;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onHide: () {
        _promptedForCurrentForegroundSession = false;
      },
      onPause: () {
        _promptedForCurrentForegroundSession = false;
      },
      onResume: () {
        _maybeAutoPromptBiometrics();
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) {
        _maybeAutoPromptBiometrics();
      }
    });
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _passphraseController.dispose();
    _passphraseFocusNode.dispose();
    super.dispose();
  }

  void _maybeAutoPromptBiometrics() {
    if (!mounted || _promptedForCurrentForegroundSession || _biometricInProgress) {
      return;
    }
    if (Repository.instance.appLockMode == AppLockMode.biometric && Repository.instance.isLocked) {
      _promptedForCurrentForegroundSession = true;
      _handleBiometricUnlock();
    }
  }

  Future<void> _handlePassphraseUnlock() async {
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
      await Repository.instance.unlockWithPassphrase(_passphraseController.text);
      _passphraseController.clear();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '$e';
      });
      _formKey.currentState?.validate();
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _handleBiometricUnlock() async {
    if (_biometricInProgress || _submitting) return;
    setState(() {
      _biometricInProgress = true;
      _infoBanner = null;
    });

    try {
      await Repository.instance.unlockWithBiometrics();
      _passphraseController.clear();
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'BIOMETRIC_CANCELED') {
        _passphraseFocusNode.requestFocus();
      } else if (e.code == 'BIOMETRIC_INVALIDATED' || e.code == 'KEY_MISSING') {
        setState(() {
          _infoBanner = e.message ??
              'Biometric enrollment changed. Unlock with your GPG passphrase and re-enable biometrics in Settings.';
        });
        _passphraseFocusNode.requestFocus();
      } else {
        setState(() {
          _infoBanner = e.message ?? 'Biometric unlock failed. Enter your GPG passphrase below.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _infoBanner = '$e';
      });
    } finally {
      if (mounted) {
        setState(() => _biometricInProgress = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Repository.instance.lockStateListenable,
      builder: (context, _) {
        final canUseBiometrics = Repository.instance.appLockMode == AppLockMode.biometric;
        final colorScheme = ColorScheme.of(context);

        return Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Form(
                    key: _formKey,
                    autovalidateMode: _autovalidateMode,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 56,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Vault Locked',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Enter your GPG passphrase to unlock your password store.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (_infoBanner != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _infoBanner!,
                              style: TextStyle(color: colorScheme.onSecondaryContainer),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        TextFormField(
                          controller: _passphraseController,
                          focusNode: _passphraseFocusNode,
                          obscureText: _obscured,
                          enableSuggestions: false,
                          autocorrect: false,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _handlePassphraseUnlock(),
                          decoration: InputDecoration(
                            labelText: 'GPG Passphrase',
                            border: const OutlineInputBorder(),
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
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _submitting ? null : _handlePassphraseUnlock,
                          child: _submitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Unlock'),
                        ),
                        if (canUseBiometrics) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: (_biometricInProgress || _submitting)
                                ? null
                                : _handleBiometricUnlock,
                            icon: const Icon(Icons.fingerprint),
                            label: const Text('Unlock with Biometrics'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
