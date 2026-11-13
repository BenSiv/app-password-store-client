import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

enum BiometricStatus {
  available,
  noneEnrolled,
  noHardware,
  unavailable;

  static BiometricStatus fromCode(String? code) {
    switch (code) {
      case 'available':
        return BiometricStatus.available;
      case 'none_enrolled':
        return BiometricStatus.noneEnrolled;
      case 'no_hardware':
        return BiometricStatus.noHardware;
      default:
        return BiometricStatus.unavailable;
    }
  }
}

final class BiometricWrappedSecret {
  const BiometricWrappedSecret({
    required this.ciphertext,
    required this.iv,
  });

  final String ciphertext;
  final String iv;

  String toJsonString() => jsonEncode({
    'ciphertext': ciphertext,
    'iv': iv,
  });

  static BiometricWrappedSecret fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid biometric wrapped secret');
    }
    final ciphertext = decoded['ciphertext'];
    final iv = decoded['iv'];
    if (ciphertext is! String || iv is! String || ciphertext.isEmpty || iv.isEmpty) {
      throw const FormatException('Incomplete biometric wrapped secret');
    }
    return BiometricWrappedSecret(ciphertext: ciphertext, iv: iv);
  }
}

abstract final class PlatformSecurity {
  static const MethodChannel _channel = MethodChannel('com.bensivan.passwordstore/security');
  static const Duration defaultClipboardTtl = Duration(seconds: 45);
  static Timer? _fallbackClipboardTimer;

  static Future<bool> isStrongBiometricAvailable() async {
    try {
      final available = await _channel.invokeMethod<bool>('isStrongBiometricAvailable');
      return available ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<BiometricStatus> getBiometricStatus() async {
    try {
      final code = await _channel.invokeMethod<String>('getBiometricStatus');
      return BiometricStatus.fromCode(code);
    } on MissingPluginException {
      return BiometricStatus.unavailable;
    } on PlatformException {
      return BiometricStatus.unavailable;
    }
  }

  static Future<BiometricWrappedSecret> encryptWithBiometrics(String plaintext) async {
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'encryptWithBiometrics',
      {'plaintext': plaintext},
    );
    if (raw == null) {
      throw PlatformException(
        code: 'CRYPTO_ERROR',
        message: 'Biometric encryption returned empty payload',
      );
    }
    final ciphertext = raw['ciphertext'] as String?;
    final iv = raw['iv'] as String?;
    if (ciphertext == null || iv == null || ciphertext.isEmpty || iv.isEmpty) {
      throw PlatformException(
        code: 'CRYPTO_ERROR',
        message: 'Biometric encryption returned incomplete payload',
      );
    }
    return BiometricWrappedSecret(ciphertext: ciphertext, iv: iv);
  }

  static Future<String> decryptWithBiometrics(BiometricWrappedSecret wrapped) async {
    final decrypted = await _channel.invokeMethod<String>(
      'decryptWithBiometrics',
      {
        'ciphertext': wrapped.ciphertext,
        'iv': wrapped.iv,
      },
    );
    if (decrypted == null || decrypted.isEmpty) {
      throw PlatformException(
        code: 'CRYPTO_ERROR',
        message: 'Biometric decryption returned empty passphrase',
      );
    }
    return decrypted;
  }

  static Future<void> clearBiometricKey() async {
    try {
      await _channel.invokeMethod<void>('clearBiometricKey');
    } on MissingPluginException {
      // Ignore on unsupported platforms/tests.
    } on PlatformException {
      // Best-effort cleanup.
    }
  }

  static Future<void> copySensitive(
    String text, {
    Duration clearAfter = defaultClipboardTtl,
  }) async {
    _fallbackClipboardTimer?.cancel();
    _fallbackClipboardTimer = null;

    try {
      await _channel.invokeMethod<void>('copySensitive', {
        'text': text,
        'clearAfterMs': clearAfter.inMilliseconds,
      });
      return;
    } on MissingPluginException {
      await Clipboard.setData(ClipboardData(text: text));
      _fallbackClipboardTimer = Timer(clearAfter, () {
        Clipboard.setData(const ClipboardData(text: ''));
      });
    }
  }

  static Future<void> clearClipboard() async {
    _fallbackClipboardTimer?.cancel();
    _fallbackClipboardTimer = null;
    try {
      await _channel.invokeMethod<void>('clearClipboard');
    } on MissingPluginException {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }
}
