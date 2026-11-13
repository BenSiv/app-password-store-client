import 'dart:async';

import 'package:app/src/data/models.dart';
import 'package:app/src/data/repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:otp/otp.dart';

final class VaultDetailScreen extends StatefulWidget {
  const VaultDetailScreen(this.path);

  final String path;

  @override
  State<StatefulWidget> createState() {
    return _VaultDetailScreenState();
  }
}

final class _VaultDetailScreenState extends State<VaultDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.path),
      ),
      body: SafeArea(
        child: StreamBuilder<Vault>(
          stream: Repository.instance.subscribeVaultDetail(widget.path),
          builder: (context, ss) {
            if (ss.hasError) return Center(child: Text('${ss.error}'));
            final vault = ss.data;
            if (vault == null) return SizedBox();
            return SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: Column(
                spacing: 16,
                children: [
                  _VaultField(label: 'vault', value: vault.vault, isPassword: true),
                  if (vault.username.isNotEmpty)
                    _VaultField(label: 'username', value: vault.username),
                  ...vault.websites.map((e) =>
                    _VaultField(label: 'website', value: e)),
                  if (vault.otpauth != null)
                    if (vault.otpauth is OtpAuthTotp)
                      _TotpVaultField(vault.otpauth as OtpAuthTotp)
                    else if (vault.otpauth is OtpAuthHotp)
                      _VaultField(label: 'verification code (hotp)', value: vault.otpauth!.raw, helper: 'Currently, HOTP is not supported'),
                  ...vault.customFields.map((e) =>
                    _VaultField(label: e.key, value: e.value)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _VaultField extends StatefulWidget {
  const _VaultField({
    required this.label,
    required this.value,
    this.isPassword = false,
    this.helper,
    this.additionalActions = const [],
  });

  final String label;

  final String value;

  final bool isPassword;

  final String? helper;

  final List<Widget> additionalActions;

  @override
  State<StatefulWidget> createState() {
    return _VaultFieldState();
  }
}

final class _VaultFieldState extends State<_VaultField> {
  late bool _obscured;

  @override
  void initState() {
    super.initState();
    _obscured = widget.isPassword;
  }

  @override
  Widget build(BuildContext context) {
    final displayValue = widget.isPassword && _obscured
        ? '•' * widget.value.length
        : widget.value;

    return InputDecorator(
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        suffixIconConstraints: BoxConstraints(),
        suffixIcon: IntrinsicWidth(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              ...widget.additionalActions,
              if (widget.isPassword)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(),
                  icon: Icon(
                    _obscured ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscured = !_obscured;
                    });
                  },
                ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(),
                icon: Icon(Icons.copy),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.value),
                  );
                  if (!context.mounted) return;
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.clearSnackBars();
                  messenger.showSnackBar(
                    SnackBar(content: Text('Copied ${widget.label}')),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      child: Text(
        displayValue,
        style: widget.isPassword && _obscured
            ? TextStyle(fontSize: 16, letterSpacing: 2)
            : null,
      ),
    );
  }
}

final class _TotpVaultField extends StatefulWidget {
  const _TotpVaultField(this.totp);

  final OtpAuthTotp totp;

  @override
  State<StatefulWidget> createState() {
    return _TotpVaultFieldState();
  }
}

final class _TotpVaultFieldState extends State<_TotpVaultField> {
  late final Timer _timer;
  String _currentCode = '';
  int _remainingSeconds = 30;
  double _progress = 1.0;
  int _lastStep = -1;

  @override
  void initState() {
    super.initState();
    _updateTotp();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTotp());
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _updateTotp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final timeInSeconds = now ~/ 1000;
    final remainingSeconds = widget.totp.period - (timeInSeconds % widget.totp.period);
    final progress = remainingSeconds / widget.totp.period;
    final currentStep = timeInSeconds ~/ widget.totp.period;

    if (currentStep != _lastStep) {
      _currentCode = OTP.generateTOTPCodeString(
        widget.totp.secret,
        now,
        length: widget.totp.digits,
        interval: widget.totp.period,
        algorithm: Algorithm.values.byName(widget.totp.algorithm),
        isGoogle: true,
      );
      _lastStep = currentStep;
    }

    setState(() {
      _remainingSeconds = remainingSeconds;
      _progress = progress;
    });
  }

  @override
  Widget build(BuildContext context) {
    final progressColor = _remainingSeconds <= 5
      ? Colors.red
      : Colors.grey;
    return _VaultField(
      label: 'verification code (totp)',
      value: _currentCode,
      additionalActions: [
        SizedBox(
          width: 24,
          height: 24,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CircularProgressIndicator(
                value: _progress,
                strokeWidth: 2,
                backgroundColor: Colors.grey.shade300,
                color: progressColor,
              ),
              Center(
                child: Text(
                  '$_remainingSeconds',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: progressColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
