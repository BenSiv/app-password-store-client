import 'dart:convert';
import 'dart:io';

import 'package:app/src/data/models.dart';
import 'package:app/src/data/repository.dart';
import 'package:app/src/utils/platform_security.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _FakeSecureStorage extends FlutterSecureStoragePlatform {
  final Map<String, String> data = {};

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async {
    return data.containsKey(key);
  }

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {
    data.remove(key);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    data.clear();
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    return data[key];
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async {
    return Map<String, String>.from(data);
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    data[key] = value;
  }
}

final class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootDir);

  final Directory rootDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => '${rootDir.path}/docs';

  @override
  Future<String?> getApplicationCachePath() async => '${rootDir.path}/cache';
}

Future<void> _runCmd(String exe, List<String> args, {Map<String, String>? env, String? stdinText}) async {
  final proc = await Process.start(exe, args, environment: env);
  if (stdinText != null) {
    proc.stdin.write(stdinText);
  }
  await proc.stdin.close();
  final stdoutText = await utf8.decodeStream(proc.stdout);
  final stderrText = await utf8.decodeStream(proc.stderr);
  final exitCode = await proc.exitCode;
  if (exitCode != 0) {
    throw StateError('Command failed ($exitCode): $exe ${args.join(' ')}\n$stdoutText\n$stderrText');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const securityChannel = MethodChannel('com.bensivan.passwordstore/security');
  const passphrase = 'master-gpg-passphrase-42!';
  const obfHash = '0a1b2c3d4e';

  late Directory tempRoot;
  late Directory gnupgDir;
  late _FakeSecureStorage fakeStorage;
  late String armoredSecretKey;
  late String primaryKeyIdHex;

  bool biometricAvailable = true;
  bool invalidateNextBiometricDecrypt = false;
  String? hardwareKeystoreWrappedPlaintext;
  Map<String, dynamic>? lastSensitiveClipboardCall;

  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('app_pw_security_test_');
    gnupgDir = Directory('${tempRoot.path}/gnupg')..createSync(recursive: true);
    await Process.run('chmod', ['700', gnupgDir.path]);

    final env = {'GNUPGHOME': gnupgDir.path};
    await _runCmd(
      'gpg',
      [
        '--batch',
        '--pinentry-mode',
        'loopback',
        '--passphrase',
        passphrase,
        '--quick-generate-key',
        'Vault Test <vault@test.local>',
        'rsa2048',
        'cert,sign',
        'never',
      ],
      env: env,
    );

    final listRes = await Process.run('gpg', ['--list-secret-keys', '--with-colons'], environment: env);
    final lines = (listRes.stdout as String).split('\n');
    final fprLine = lines.firstWhere((l) => l.startsWith('fpr:'));
    final fingerprint = fprLine.split(':')[9];
    primaryKeyIdHex = fingerprint.substring(fingerprint.length - 16).toUpperCase();

    await _runCmd(
      'gpg',
      [
        '--batch',
        '--pinentry-mode',
        'loopback',
        '--passphrase',
        passphrase,
        '--quick-add-key',
        fingerprint,
        'rsa2048',
        'encr',
        'never',
      ],
      env: env,
    );

    final exportRes = await Process.run(
      'gpg',
      [
        '--batch',
        '--pinentry-mode',
        'loopback',
        '--passphrase',
        passphrase,
        '--armor',
        '--export-secret-keys',
        fingerprint,
      ],
      environment: env,
    );
    armoredSecretKey = exportRes.stdout as String;

    final repoDir = Directory('${tempRoot.path}/docs/git-repository')..createSync(recursive: true);
    Directory('${tempRoot.path}/cache').createSync(recursive: true);
    File('${repoDir.path}/.gpg-id').writeAsStringSync('$primaryKeyIdHex\n');

    await _runCmd(
      'gpg',
      [
        '--batch',
        '--yes',
        '--always-trust',
        '--encrypt',
        '--recipient',
        fingerprint,
        '--output',
        '${repoDir.path}/index.gpg',
      ],
      env: env,
      stdinText: 'github/personal : $obfHash\n__salt__ : deadbeefcafebabe\n',
    );

    await _runCmd(
      'gpg',
      [
        '--batch',
        '--yes',
        '--always-trust',
        '--encrypt',
        '--recipient',
        fingerprint,
        '--output',
        '${repoDir.path}/$obfHash.gpg',
      ],
      env: env,
      stdinText: 's3cr3t-vault-pw!\nusername: bensiv\nwebsite: https://github.com\n',
    );
  });

  tearDownAll(() async {
    await Process.run('gpgconf', ['--kill', 'gpg-agent'], environment: {'GNUPGHOME': gnupgDir.path});
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fakeStorage = _FakeSecureStorage();
    FlutterSecureStoragePlatform.instance = fakeStorage;
    PathProviderPlatform.instance = _FakePathProvider(tempRoot);

    biometricAvailable = true;
    invalidateNextBiometricDecrypt = false;
    hardwareKeystoreWrappedPlaintext = null;
    lastSensitiveClipboardCall = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      securityChannel,
      (call) async {
        switch (call.method) {
          case 'isStrongBiometricAvailable':
            return biometricAvailable;
          case 'getBiometricStatus':
            return biometricAvailable ? 'available' : 'none_enrolled';
          case 'encryptWithBiometrics':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            hardwareKeystoreWrappedPlaintext = args['plaintext'] as String;
            return <String, dynamic>{
              'ciphertext': base64Encode(utf8.encode('wrapped')),
              'iv': base64Encode(List<int>.filled(12, 7)),
            };
          case 'decryptWithBiometrics':
            if (invalidateNextBiometricDecrypt) {
              hardwareKeystoreWrappedPlaintext = null;
              throw PlatformException(
                code: 'BIOMETRIC_INVALIDATED',
                message: 'Biometric enrollment changed',
              );
            }
            if (hardwareKeystoreWrappedPlaintext == null) {
              throw PlatformException(code: 'KEY_MISSING', message: 'Key missing');
            }
            return hardwareKeystoreWrappedPlaintext;
          case 'clearBiometricKey':
            hardwareKeystoreWrappedPlaintext = null;
            return null;
          case 'copySensitive':
            lastSensitiveClipboardCall = Map<String, dynamic>.from(call.arguments as Map);
            return null;
          case 'clearClipboard':
            return null;
          default:
            return null;
        }
      },
    );

    await Repository.instance.initialize();
  });

  test('Master Password mode removes plaintext passphrase, locks on background, and decrypts CamoPass store on unlock', () async {
    await Repository.instance.saveGpgPrivateKey(
      armored: armoredSecretKey,
      passphrase: passphrase,
    );
    expect(fakeStorage.data['gpg-key-passphrase'], passphrase);

    // Enable Master Password (GPG Passphrase) lock mode
    await Repository.instance.setAppLockMode(
      AppLockMode.masterPassword,
      passphrase: passphrase,
    );
    expect(Repository.instance.appLockMode, AppLockMode.masterPassword);
    expect(fakeStorage.data.containsKey('gpg-key-passphrase'), isFalse);
    expect(Repository.instance.isLocked, isFalse);

    // Suspended auto-lock (e.g. during system sheet) does not lock
    await Repository.instance.runWithAutoLockSuspended(() async {
      Repository.instance.onAppBackgrounded();
      expect(Repository.instance.isLocked, isFalse);
    });

    // Backgrounding locks immediately
    Repository.instance.onAppBackgrounded();
    expect(Repository.instance.isLocked, isTrue);
    await expectLater(Repository.instance.subscribeVaultList().first, throwsA('Vault is locked'));
    await expectLater(
      Repository.instance.subscribeVaultDetail('github/personal').first,
      throwsA('Vault is locked'),
    );

    // Wrong passphrase rejected
    await expectLater(
      Repository.instance.unlockWithPassphrase('wrong-passphrase'),
      throwsA('Passphrase missmatch'),
    );
    expect(Repository.instance.isLocked, isTrue);

    // Correct GPG passphrase unlocks and decrypts CamoPass index + obfuscated entry
    await Repository.instance.unlockWithPassphrase(passphrase);
    expect(Repository.instance.isLocked, isFalse);

    final vaults = await Repository.instance.subscribeVaultList().first;
    expect(vaults.toList(), ['github/personal']);

    final detail = await Repository.instance.subscribeVaultDetail('github/personal').first;
    expect(detail.vault, 's3cr3t-vault-pw!');
    expect(detail.username, 'bensiv');
    expect(detail.websites.toList(), ['https://github.com']);
  });

  test('Strong Biometric mode wraps GPG passphrase, unlocks via CryptoObject, and falls back safely on invalidation', () async {
    await Repository.instance.saveGpgPrivateKey(
      armored: armoredSecretKey,
      passphrase: passphrase,
    );

    await Repository.instance.setAppLockMode(
      AppLockMode.biometric,
      passphrase: passphrase,
    );
    expect(Repository.instance.appLockMode, AppLockMode.biometric);
    expect(fakeStorage.data.containsKey('gpg-key-passphrase'), isFalse);
    expect(fakeStorage.data.containsKey('biometric-wrapped-passphrase'), isTrue);

    // Cold-start simulation starts locked immediately
    await Repository.instance.initialize();
    expect(Repository.instance.isLocked, isTrue);

    // Biometric unlock restores session and decrypts CamoPass entry
    await Repository.instance.unlockWithBiometrics();
    expect(Repository.instance.isLocked, isFalse);
    final detail = await Repository.instance.subscribeVaultDetail('github/personal').first;
    expect(detail.vault, 's3cr3t-vault-pw!');

    // Background + biometric enrollment change invalidates key and downgrades to Master Password mode
    Repository.instance.onAppBackgrounded();
    expect(Repository.instance.isLocked, isTrue);
    invalidateNextBiometricDecrypt = true;

    await expectLater(
      Repository.instance.unlockWithBiometrics(),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'BIOMETRIC_INVALIDATED')),
    );
    expect(Repository.instance.appLockMode, AppLockMode.masterPassword);
    expect(fakeStorage.data.containsKey('biometric-wrapped-passphrase'), isFalse);
    expect(Repository.instance.isLocked, isTrue);

    // GPG passphrase fallback still unlocks cleanly
    await Repository.instance.unlockWithPassphrase(passphrase);
    expect(Repository.instance.isLocked, isFalse);
  });

  test('Sensitive clipboard copy sends 45-second auto-clear TTL to native channel', () async {
    await PlatformSecurity.copySensitive('top-secret-password');
    expect(lastSensitiveClipboardCall, {
      'text': 'top-secret-password',
      'clearAfterMs': 45000,
    });
  });
}
