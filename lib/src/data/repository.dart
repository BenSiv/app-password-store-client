import 'dart:convert';
import 'dart:io';

import 'package:app/src/data/git2.dart';
import 'package:app/src/data/models.dart';
import 'package:app/src/data/subscription_manager.dart';
import 'package:dart_pg/dart_pg.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
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
  final SubscriptionManager _subscriptionManager = SubscriptionManager();

  Future<Map<String, String>?> _loadIndex({PrivateKey? unlockedKey}) async {
    final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
    final indexFile = File('${repoDir.path}/index.gpg');
    if (!indexFile.existsSync()) {
      return null;
    }

    try {
      final PrivateKey key;
      if (unlockedKey != null) {
        key = unlockedKey;
      } else {
        final armored = await FlutterSecureStorage().read(key: 'gpg-key');
        final passphrase = await FlutterSecureStorage().read(key: 'gpg-key-passphrase');
        if (armored == null) {
          return null;
        }
        key = verifyGpgPrivateKey(armored: armored, passphrase: passphrase);
      }

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
          final key = line.substring(0, colonIdx).trim();
          final val = line.substring(colonIdx + 1).trim();
          if (key != '__salt__') {
            mappings[key] = val;
          }
        }
      }
      return mappings;
    } catch (e) {
      return null;
    }
  }

  Stream<Iterable<String>> subscribeVaultList() {
    return _subscriptionManager.createStream(() async {
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

      final indexMappings = await _loadIndex();
      if (indexMappings != null) {
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
      final armored = await FlutterSecureStorage().read(key: 'gpg-key');
      final passphrase = await FlutterSecureStorage().read(key: 'gpg-key-passphrase');
      final unlockedKey = armored == null ? null : verifyGpgPrivateKey(armored: armored, passphrase: passphrase);

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

      if (unlockedKey == null) {
        throw 'GPG key not found';
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
      final credentialString = await FlutterSecureStorage().read(key: 'git-credential');
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
    (await SharedPreferences.getInstance()).setString('git-repository-last-sync', DateTime.now().toIso8601String());
  }

  Future<void> syncCurrentGitRepository() async {
    final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
    if (!repoDir.existsSync()) {
      throw 'Git repository not found';
    }

    final repo = GitRepository.open(path: repoDir.path);
    final credentialString = await FlutterSecureStorage().read(key: 'git-credential');
    final credential = credentialString == null ? null : GitCredential.decodeStored(credentialString);
    await _syncGitRepository(url: repo.originUrl, branch: repo.currentBranch, credential: credential);
    _subscriptionManager.publish();
  }

  Future<void> syncAndSaveGitRepository({required String url, String? branch, GitCredential? credential}) async {
    await _syncGitRepository(url: url, branch: branch, credential: credential);
    final credentialString = credential?.toJson();
    await FlutterSecureStorage().write(key: 'git-credential', value: credentialString);
    _subscriptionManager.publish();
  }

  Stream<PrivateKey> subscribeGpgPrivateKey() {
    return _subscriptionManager.createStream(() async {
      final armored = await FlutterSecureStorage().read(key: 'gpg-key');

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

    await FlutterSecureStorage().write(key: 'gpg-key', value: armored);
    await FlutterSecureStorage().write(key: 'gpg-key-passphrase', value: passphrase);
    _subscriptionManager.publish();
  }

  Future<void> eraseAllData() async {
    (await getApplicationDocumentsDirectory()).deleteSync(recursive: true);
    (await SharedPreferences.getInstance()).clear();
    await FlutterSecureStorage().deleteAll();
    _subscriptionManager.publish();
  }
}
