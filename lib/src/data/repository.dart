import 'dart:convert';
import 'dart:io';

import 'package:app/src/data/git2.dart';
import 'package:app/src/data/models.dart';
import 'package:app/src/data/subscription_manager.dart';
import 'package:app/src/utils/platform_security.dart';
import 'package:dart_pg/dart_pg.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Vault _parseVault(String raw) {
  final lines = raw.trim().split(RegExp(r'\r?\n'));

  if (lines.isEmpty) {
    throw FormatException('Vault has no content');
  }

  final vault = lines.removeAt(0);
  var username = ''; // NOTE: username is non-nullable.
  final websites = <String>[];
  final customFields = <MapEntry<String, String>>[];
  OtpAuth? otpauth;

  for (var line in lines) {
    line = line.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('otpauth://')) {
      otpauth = OtpAuth.tryParse(line);
      continue;
    }

    // TODO: Allows users to specify separators and field names
    final keyIndex = line.indexOf(': ');
    if (keyIndex < 0) {
      customFields.add(MapEntry('', line));
    } else {
      final key = line.substring(0, keyIndex);
      final value = line.substring(keyIndex + 2);

      if (key.toLowerCase() == 'username') {
        username = value;
      } else if (key.toLowerCase() == 'website') {
        websites.add(value);
      } else {
        customFields.add(MapEntry(key, value));
      }
    }
  }

  return Vault(
    raw: raw,
    vault: vault,
    username: username,
    websites: websites.toIList(),
    otpauth: otpauth,
    customFields: customFields.toIList(),
  );
}

final class Repository {
  Repository._();
  static Repository? _instance;
  static Repository get instance => _instance ??= Repository._();

  static const String _appLockModePrefKey = 'app-lock-mode';
  static const String _gpgKeyStorageKey = 'gpg-key';
  static const String _gpgPassphraseStorageKey = 'gpg-key-passphrase';
  static const String _biometricWrappedStorageKey = 'biometric-wrapped-passphrase';
  static const String _gitCredentialStorageKey = 'git-credential';

  final SubscriptionManager _subscriptionManager = SubscriptionManager();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final ValueNotifier<int> _lockStateVersion = ValueNotifier<int>(0);

  AppLockMode _appLockMode = AppLockMode.off;
  bool _isLocked = false;
  PrivateKey? _unlockedPrivateKey;
  Map<String, String>? _cachedIndex;
  int _autoLockSuspendCount = 0;

  Listenable get lockStateListenable => _lockStateVersion;
  AppLockMode get appLockMode => _appLockMode;
  bool get isLocked => _isLocked;
  bool get isAppLockEnabled => _appLockMode != AppLockMode.off;

  void _notifyLockStateChanged() {
    _lockStateVersion.value++;
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final configuredMode = AppLockMode.fromStorage(prefs.getString(_appLockModePrefKey));
    final armored = await _secureStorage.read(key: _gpgKeyStorageKey);

    if (armored == null) {
      _appLockMode = AppLockMode.off;
      _isLocked = false;
      _unlockedPrivateKey = null;
      _cachedIndex = null;
      if (configuredMode != AppLockMode.off) {
        await prefs.setString(_appLockModePrefKey, AppLockMode.off.storageValue);
      }
      return;
    }

    _appLockMode = configuredMode;
    if (_appLockMode != AppLockMode.off) {
      // Ensure plaintext passphrase is never persisted on disk when App Lock is active.
      await _secureStorage.delete(key: _gpgPassphraseStorageKey);
      _unlockedPrivateKey = null;
      _cachedIndex = null;
      _isLocked = true;
    } else {
      _isLocked = false;
    }
  }

  void lock() {
    if (_appLockMode == AppLockMode.off) {
      return;
    }
    _unlockedPrivateKey = null;
    _cachedIndex = null;
    if (!_isLocked) {
      _isLocked = true;
      _notifyLockStateChanged();
    }
  }

  void onAppBackgrounded() {
    if (_autoLockSuspendCount > 0) {
      return;
    }
    if (_appLockMode != AppLockMode.off) {
      lock();
    }
  }

  Future<T> runWithAutoLockSuspended<T>(Future<T> Function() action) async {
    _autoLockSuspendCount++;
    try {
      return await action();
    } finally {
      _autoLockSuspendCount--;
    }
  }

  Future<bool> hasGpgKey() async {
    final armored = await _secureStorage.read(key: _gpgKeyStorageKey);
    return armored != null;
  }

  Future<bool> hasEncryptedGpgKey() async {
    final armored = await _secureStorage.read(key: _gpgKeyStorageKey);
    if (armored == null) {
      return false;
    }
    try {
      final key = OpenPGP.readPrivateKey(armored) as PrivateKey;
      return key.isEncrypted;
    } catch (_) {
      return false;
    }
  }

  Future<void> unlockWithPassphrase(String passphrase) async {
    final armored = await _secureStorage.read(key: _gpgKeyStorageKey);
    if (armored == null) {
      throw 'GPG key not found';
    }

    final unlockedKey = verifyGpgPrivateKey(armored: armored, passphrase: passphrase);
    _unlockedPrivateKey = unlockedKey;
    _cachedIndex = null;
    _isLocked = false;
    _notifyLockStateChanged();
    _subscriptionManager.publish();
  }

  Future<void> unlockWithBiometrics() async {
    if (_appLockMode != AppLockMode.biometric) {
      throw 'Biometric unlock is not enabled';
    }

    final wrappedRaw = await _secureStorage.read(key: _biometricWrappedStorageKey);
    if (wrappedRaw == null) {
      throw PlatformException(
        code: 'KEY_MISSING',
        message: 'Biometric unlock data is missing. Please unlock with your GPG passphrase.',
      );
    }

    final wrapped = BiometricWrappedSecret.fromJsonString(wrappedRaw);
    try {
      final passphrase = await runWithAutoLockSuspended(
        () => PlatformSecurity.decryptWithBiometrics(wrapped),
      );
      await unlockWithPassphrase(passphrase);
    } on PlatformException catch (e) {
      if (e.code == 'BIOMETRIC_INVALIDATED' || e.code == 'KEY_MISSING') {
        await _secureStorage.delete(key: _biometricWrappedStorageKey);
        await PlatformSecurity.clearBiometricKey();
        _appLockMode = AppLockMode.masterPassword;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_appLockModePrefKey, _appLockMode.storageValue);
        _notifyLockStateChanged();
      }
      rethrow;
    }
  }

  Future<void> setAppLockMode(
    AppLockMode mode, {
    required String passphrase,
  }) async {
    final armored = await _secureStorage.read(key: _gpgKeyStorageKey);
    if (armored == null) {
      throw 'Import a GPG private key before configuring App Lock.';
    }

    late final PrivateKey parsedKey;
    try {
      parsedKey = OpenPGP.readPrivateKey(armored) as PrivateKey;
    } catch (_) {
      throw 'GPG key malformed';
    }

    if (mode != AppLockMode.off && !parsedKey.isEncrypted) {
      throw 'Your GPG private key has no passphrase. Import a passphrase-protected GPG key to enable App Lock.';
    }

    final unlockedKey = verifyGpgPrivateKey(armored: armored, passphrase: passphrase);

    switch (mode) {
      case AppLockMode.off:
        await _secureStorage.write(
          key: _gpgPassphraseStorageKey,
          value: parsedKey.isEncrypted ? passphrase : null,
        );
        await _secureStorage.delete(key: _biometricWrappedStorageKey);
        await PlatformSecurity.clearBiometricKey();
      case AppLockMode.masterPassword:
        await _secureStorage.delete(key: _gpgPassphraseStorageKey);
        await _secureStorage.delete(key: _biometricWrappedStorageKey);
        await PlatformSecurity.clearBiometricKey();
      case AppLockMode.biometric:
        final available = await PlatformSecurity.isStrongBiometricAvailable();
        if (!available) {
          throw 'Strong biometrics (Class 3 fingerprint/face) are not available or enrolled on this device.';
        }
        final wrapped = await runWithAutoLockSuspended(
          () => PlatformSecurity.encryptWithBiometrics(passphrase),
        );
        await _secureStorage.write(
          key: _biometricWrappedStorageKey,
          value: wrapped.toJsonString(),
        );
        await _secureStorage.delete(key: _gpgPassphraseStorageKey);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appLockModePrefKey, mode.storageValue);

    _appLockMode = mode;
    _unlockedPrivateKey = unlockedKey;
    _isLocked = false;
    _notifyLockStateChanged();
    _subscriptionManager.publish();
  }

  Future<PrivateKey> _obtainUnlockedKey() async {
    if (_isLocked) {
      throw 'Vault is locked';
    }
    if (_unlockedPrivateKey != null) {
      return _unlockedPrivateKey!;
    }

    final armored = await _secureStorage.read(key: _gpgKeyStorageKey);
    if (armored == null) {
      throw 'GPG key not found';
    }

    if (_appLockMode != AppLockMode.off) {
      _isLocked = true;
      _notifyLockStateChanged();
      throw 'Vault is locked';
    }

    final passphrase = await _secureStorage.read(key: _gpgPassphraseStorageKey);
    final unlockedKey = verifyGpgPrivateKey(armored: armored, passphrase: passphrase);
    _unlockedPrivateKey = unlockedKey;
    return unlockedKey;
  }

  Future<Map<String, String>?> _loadIndex({PrivateKey? unlockedKey}) async {
    if (_cachedIndex != null) {
      return _cachedIndex;
    }

    final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
    final indexFile = File('${repoDir.path}/index.gpg');
    if (!indexFile.existsSync()) {
      return null;
    }

    try {
      final key = unlockedKey ?? await _obtainUnlockedKey();
      final packetList = PacketList.decode(indexFile.readAsBytesSync());
      final message = EncryptedMessage(packetList);
      final decryptedBytes = OpenPGP.decryptMessage(message, decryptionKeys: [key]).literalData.binary;
      final decryptedText = utf8.decode(decryptedBytes);
      final lines = decryptedText.trim().split(RegExp(r'\r?\n'));
      final Map<String, String> mappings = {};
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty) continue;
        final colonIdx = line.indexOf(':');
        if (colonIdx >= 0) {
          final entryKey = line.substring(0, colonIdx).trim();
          final val = line.substring(colonIdx + 1).trim();
          if (entryKey != '__salt__') {
            mappings[entryKey] = val;
          }
        }
      }
      _cachedIndex = mappings;
      return mappings;
    } catch (e) {
      return null;
    }
  }

  Stream<Iterable<String>> subscribeVaultList() {
    return _subscriptionManager.createStream(() async {
      if (_isLocked) {
        throw 'Vault is locked';
      }

      final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
      if (!repoDir.existsSync()) {
        throw 'Git repository not found';
      }

      final gpgIdFile = File('${repoDir.path}/.gpg-id');
      if (!gpgIdFile.existsSync()) {
        throw 'Git repository missing .gpg-id';
      }

      final privateKey = await subscribeGpgPrivateKey().first;
      final gpgIds = gpgIdFile.readAsStringSync().split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty);
      final keyId = privateKey.keyID.map((e) => e.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
      if (!gpgIds.contains(keyId)) {
        throw 'GPG key missing from .gpg-id: keyId=$keyId';
      }

      final unlockedKey = await _obtainUnlockedKey();
      final indexFile = File('${repoDir.path}/index.gpg');
      if (indexFile.existsSync()) {
        final indexMappings = await _loadIndex(unlockedKey: unlockedKey);
        if (indexMappings == null) {
          throw 'Failed to decrypt index.gpg';
        }
        return indexMappings.keys.toList()..sort((a, b) => a.compareTo(b));
      }

      return repoDir.listSync(recursive: true)
        .where((e) => e.path.endsWith('.gpg') && !e.path.endsWith('index.gpg'))
        .map((e) => e.path.split('${repoDir.path}/').last.split('.gpg').first)
        .toList()..sort((a, b) => a.compareTo(b));
    });
  }

  Stream<Vault> subscribeVaultDetail(String path) {
    return _subscriptionManager.createStream(() async {
      final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
      final unlockedKey = await _obtainUnlockedKey();

      File file;
      final indexMappings = await _loadIndex(unlockedKey: unlockedKey);
      if (indexMappings != null && indexMappings.containsKey(path)) {
        final hashName = indexMappings[path];
        file = File('${repoDir.path}/$hashName.gpg');
      } else {
        file = File('${repoDir.path}/$path.gpg');
      }

      if (!file.existsSync()) {
        throw 'Vault not found: path=$path';
      }

      final packetList = PacketList.decode(file.readAsBytesSync());
      final message = EncryptedMessage(packetList);
      final decrypted = OpenPGP.decryptMessage(message, decryptionKeys: [unlockedKey]).literalData.binary;
      return _parseVault(utf8.decode(decrypted));
    });
  }

  Stream<GitRepositoryMetadata> subscribeGitRepositoryMetadata() {
    return _subscriptionManager.createStream(() async {
      final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
      if (!repoDir.existsSync()) {
        throw 'Git repository not found';
      }

      final gpgIdFile = File('${repoDir.path}/.gpg-id');
      if (!gpgIdFile.existsSync()) {
        throw 'Git repository missing .gpg-id';
      }

      final repo = GitRepository.open(path: repoDir.path);
      final gpgIds = gpgIdFile.readAsStringSync().split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty);
      final lastSync = (await SharedPreferences.getInstance()).getString('git-repository-last-sync');
      final credentialString = await _secureStorage.read(key: _gitCredentialStorageKey);
      final credential = credentialString == null ? null : GitCredential.decodeStored(credentialString);
      final numberOfVaults = repoDir.listSync(recursive: true).map((e) => e.path).where((e) => e.endsWith('.gpg') && !e.endsWith('index.gpg')).length;

      return GitRepositoryMetadata(
        url: repo.originUrl,
        branch: repo.currentBranch,
        lastSync: lastSync ?? "-",
        commitHash: repo.commitHash,
        gpgIds: gpgIds.toIList(),
        numberOfVaults: numberOfVaults,
        credential: credential,
      );
    });
  }

  Future<void> _syncGitRepository({required String url, String? branch, GitCredential? credential}) async {
    final repoDirCache = Directory('${(await getApplicationCacheDirectory()).path}/${DateTime.now().microsecondsSinceEpoch}');
    GitRepository.clone(url: url, localPath: repoDirCache.path, checkoutBranch: branch, credential: credential);

    final gpgIdFile = File('${repoDirCache.path}/.gpg-id');
    if (!gpgIdFile.existsSync()) {
      throw 'Git repository missing .gpg-id';
    }

    final invalidFiles = repoDirCache.listSync(recursive: true).where((e) =>
      e.statSync().type == FileSystemEntityType.file &&
      !e.path.startsWith('${repoDirCache.path}/.git/') &&
      !e.path.endsWith('.gpg-id') &&
      !e.path.endsWith('.gitattributes') &&
      !e.path.endsWith('.gpg')
    );
    if (invalidFiles.isNotEmpty) {
      throw 'Git repository contains invalid files: invalidFiles=$invalidFiles';
    }

    final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
    if (repoDir.existsSync()) {
      repoDir.deleteSync(recursive: true);
    }

    repoDirCache.renameSync(repoDir.path);
    _cachedIndex = null;
    (await SharedPreferences.getInstance()).setString('git-repository-last-sync', DateTime.now().toIso8601String());
  }

  Future<void> syncCurrentGitRepository() async {
    final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
    if (!repoDir.existsSync()) {
      throw 'Git repository not found';
    }

    final repo = GitRepository.open(path: repoDir.path);
    final credentialString = await _secureStorage.read(key: _gitCredentialStorageKey);
    final credential = credentialString == null ? null : GitCredential.decodeStored(credentialString);
    await _syncGitRepository(url: repo.originUrl, branch: repo.currentBranch, credential: credential);
    _subscriptionManager.publish();
  }

  Future<void> syncAndSaveGitRepository({required String url, String? branch, GitCredential? credential}) async {
    await _syncGitRepository(url: url, branch: branch, credential: credential);
    final credentialString = credential?.toJson();
    await _secureStorage.write(key: _gitCredentialStorageKey, value: credentialString);
    _subscriptionManager.publish();
  }

  Stream<PrivateKey> subscribeGpgPrivateKey() {
    return _subscriptionManager.createStream(() async {
      final armored = await _secureStorage.read(key: _gpgKeyStorageKey);

      if (armored == null) {
        throw 'GPG key not found';
      }

      return OpenPGP.readPrivateKey(armored) as PrivateKey;
    });
  }

  PrivateKey verifyGpgPrivateKey({required String armored, String? passphrase}) {
    late final PrivateKey privateKey;

    try {
      privateKey = OpenPGP.readPrivateKey(armored) as PrivateKey;
    } catch (e) {
      throw 'GPG key malformed';
    }

    if (!privateKey.isEncrypted) {
      return privateKey;
    }

    if (passphrase == null || passphrase.isEmpty) {
      throw 'Passphrase required';
    }

    try {
      return OpenPGP.decryptPrivateKey(armored, passphrase) as PrivateKey;
    } catch (e) {
      throw 'Passphrase missmatch';
    }
  }

  Future<void> saveGpgPrivateKey({required String armored, String? passphrase}) async {
    final privateKey = verifyGpgPrivateKey(armored: armored, passphrase: passphrase);

    final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
    if (!repoDir.existsSync()) {
      throw 'Git repository not found';
    }

    final gpgIdFile = File('${repoDir.path}/.gpg-id');
    if (!gpgIdFile.existsSync()) {
      throw 'Git repository missing .gpg-id';
    }

    final keyId = privateKey.keyID.map((e) => e.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    final gpgIds = gpgIdFile.readAsStringSync().split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty);
    if (!gpgIds.contains(keyId)) {
      throw 'GPG key missing from .gpg-id: keyId=$keyId';
    }

    await _secureStorage.write(key: _gpgKeyStorageKey, value: armored);
    _unlockedPrivateKey = privateKey;
    _cachedIndex = null;

    final rawKey = OpenPGP.readPrivateKey(armored) as PrivateKey;
    if (!rawKey.isEncrypted) {
      await _secureStorage.delete(key: _gpgPassphraseStorageKey);
      await _secureStorage.delete(key: _biometricWrappedStorageKey);
      await PlatformSecurity.clearBiometricKey();
      if (_appLockMode != AppLockMode.off) {
        _appLockMode = AppLockMode.off;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_appLockModePrefKey, AppLockMode.off.storageValue);
      }
    } else if (_appLockMode == AppLockMode.off) {
      await _secureStorage.write(key: _gpgPassphraseStorageKey, value: passphrase);
    } else {
      // Never store plaintext passphrase when App Lock is active.
      await _secureStorage.delete(key: _gpgPassphraseStorageKey);
      if (_appLockMode == AppLockMode.biometric) {
        await _secureStorage.delete(key: _biometricWrappedStorageKey);
        await PlatformSecurity.clearBiometricKey();
        _appLockMode = AppLockMode.masterPassword;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_appLockModePrefKey, AppLockMode.masterPassword.storageValue);
      }
    }

    _isLocked = false;
    _notifyLockStateChanged();
    _subscriptionManager.publish();
  }

  Future<void> eraseAllData() async {
    _unlockedPrivateKey = null;
    _cachedIndex = null;
    _appLockMode = AppLockMode.off;
    _isLocked = false;

    final docsDir = await getApplicationDocumentsDirectory();
    if (docsDir.existsSync()) {
      docsDir.deleteSync(recursive: true);
    }
    (await SharedPreferences.getInstance()).clear();
    await _secureStorage.deleteAll();
    await PlatformSecurity.clearBiometricKey();
    await PlatformSecurity.clearClipboard();
    _notifyLockStateChanged();
    _subscriptionManager.publish();
  }
}
