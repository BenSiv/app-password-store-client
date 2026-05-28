import 'dart:convert';
import 'dart:io';

import 'package:app/src/data/git2.dart';
import 'package:app/src/data/models.dart';
import 'package:app/src/data/subscription_manager.dart';
import 'package:dart_pg/dart_pg.dart' as dart_pg;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openpgp/openpgp.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Vault _parseVault(String raw) {
  final lines = raw.trim().split(RegExp(r'\r?\n'));

  if (lines.isEmpty) {
    throw FormatException('Vault has no content');
  }

  return Vault((b) {
    b.raw = raw;
    b.vault = lines.removeAt(0);
    b.username = ''; // NOTE: username is non-nullable.

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      // TODO: Allows users to specify separators and field names
      final keyIndex = line.indexOf(': ');
      if (keyIndex < 0) {
        b.customFields.add(MapEntry("", line));
      } else {
        final key = line.substring(0, keyIndex);
        final value = line.substring(keyIndex + 2);
        if (key.toLowerCase() == 'username') {
          b.username = value;
        } else if (key.toLowerCase() == 'website') {
          b.websites.add(value);
        } else {
          b.customFields.add(MapEntry(key, value));
        }
      }
    }
  });
}

final class Repository {
  Repository._();
  static Repository? _instance;
  static Repository get instance => _instance ??= Repository._();
  final SubscriptionManager _subscriptionManager = SubscriptionManager();

  Future<Map<String, String>?> _loadIndex() async {
    final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
    final indexFile = File('${repoDir.path}/index.gpg');
    if (!indexFile.existsSync()) {
      return null;
    }

    final privateKey = await FlutterSecureStorage().read(key: 'gpg-key');
    final passphrase = await FlutterSecureStorage().read(key: 'gpg-key-passphrase');
    if (privateKey == null) {
      return null;
    }

    try {
      final decryptedBytes = await OpenPGP.decryptBytes(indexFile.readAsBytesSync(), privateKey, passphrase ?? '');
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
      File file;

      final indexMappings = await _loadIndex();
      if (indexMappings != null && indexMappings.containsKey(path)) {
        final hashName = indexMappings[path];
        file = File('${repoDir.path}/$hashName.gpg');
      } else {
        file = File('${repoDir.path}/$path.gpg');
      }

      if (!file.existsSync()) {
        throw 'Vault not found: path=$path';
      }

      final privateKey = await FlutterSecureStorage().read(key: 'gpg-key');
      final passphrase = await FlutterSecureStorage().read(key: 'gpg-key-passphrase');

      if (privateKey == null) {
        throw 'GPG key not found';
      }

      final raw = utf8.decode(await OpenPGP.decryptBytes(file.readAsBytesSync(), privateKey, passphrase ?? ''));
      return _parseVault(raw);
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
      final credential = credentialString == null ? null : GitCredential.fromJson(jsonDecode(credentialString));
      final numberOfVaults = repoDir.listSync(recursive: true).map((e) => e.path).where((e) => e.endsWith('.gpg')).length;

      return GitRepositoryMetadata((b) => b
        ..url = repo.originUrl
        ..branch = repo.currentBranch
        ..credential = credential
        ..commitHash = repo.commitHash
        ..lastSync = lastSync
        ..gpgIds.replace(gpgIds)
        ..numberOfVaults = numberOfVaults
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

    final invalidFiles = repoDirCache.listSync(recursive: true)
      .where((e) => e.statSync().type == FileSystemEntityType.file && !e.path.startsWith('${repoDirCache.path}/.git/') && !e.path.endsWith('.gpg-id') && !e.path.endsWith('.gpg'));
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
    final credential = credentialString == null ? null : GitCredential.fromJson(jsonDecode(credentialString));
    await _syncGitRepository(url: repo.originUrl, branch: repo.currentBranch, credential: credential);
    _subscriptionManager.publish();
  }

  Future<void> syncAndSaveGitRepository({required String url, String? branch, GitCredential? credential}) async {
    await _syncGitRepository(url: url, branch: branch, credential: credential);
    final credentialString = credential == null ? null : jsonEncode(GitCredential.toJson(credential));
    await FlutterSecureStorage().write(key: 'git-credential', value: credentialString);
    _subscriptionManager.publish();
  }

  Stream<dart_pg.PrivateKey> subscribeGpgPrivateKey() {
    return _subscriptionManager.createStream(() async {
      final armored = await FlutterSecureStorage().read(key: 'gpg-key');

      if (armored == null) {
        throw 'GPG key not found';
      }

      return dart_pg.OpenPGP.readPrivateKey(armored) as dart_pg.PrivateKey;
    });
  }

  Future<PrivateKeyMetadata> verifyGpgPrivateKey({required String armored, String? passphrase}) async {
    late final PrivateKeyMetadata privateKey;

    try {
      privateKey = await OpenPGP.getPrivateKeyMetadata(armored);
    } on OpenPGPException {
      throw 'GPG key malformed';
    }

    if (privateKey.encrypted) {
      if (passphrase == null) {
        throw 'Passphrase required';
      }

      try {
        final encrypted = await OpenPGP.encrypt('test', await OpenPGP.convertPrivateKeyToPublicKey(armored));
        await OpenPGP.decrypt(encrypted, armored, passphrase);
      } on Exception {
        throw 'Passphrase missmatch';
      }
    }

    return privateKey;
  }

  Future<void> saveGpgPrivateKey({required String armored, String? passphrase}) async {
    final privateKey = await verifyGpgPrivateKey(armored: armored, passphrase: passphrase);

    final repoDir = Directory('${(await getApplicationDocumentsDirectory()).path}/git-repository');
    if (!repoDir.existsSync()) {
      throw 'Git repository not found';
    }

    final gpgIdFile = File('${repoDir.path}/.gpg-id');
    if (!gpgIdFile.existsSync()) {
      throw 'Git repository missing .gpg-id';
    }

    final gpgIds = gpgIdFile.readAsStringSync().split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty);
    if (!gpgIds.contains(privateKey.keyId)) {
      throw 'GPG key missing from .gpg-id: keyId=${privateKey.keyId}';
    }

    await FlutterSecureStorage().write(key: 'gpg-key', value: armored);
    await FlutterSecureStorage().write(key: 'gpg-key-passphrase', value: passphrase);
    _subscriptionManager.publish();
  }

  /* TODO: uncomment if needed
  Future<void> eraseAllData() async {
    (await getApplicationDocumentsDirectory()).deleteSync(recursive: true);
    (await SharedPreferences.getInstance()).clear();
    await FlutterSecureStorage().deleteAll();
    _subscriptionManager.publish();
  }
  */
}
