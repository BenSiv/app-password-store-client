import 'dart:convert';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';

part 'models.mapper.dart';

@MappableClass(discriminatorKey: 'type')
sealed class GitCredential with GitCredentialMappable {
  const GitCredential();

  static GitCredential decodeStored(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      if (!decoded.containsKey('type') && decoded.containsKey(r'$')) {
        return GitCredentialMapper.fromMap({
          ...decoded,
          'type': decoded[r'$'],
        });
      }
      return GitCredentialMapper.fromMap(decoded);
    }
    if (decoded is String) {
      return decodeStored(decoded);
    }
    throw FormatException('Invalid stored GitCredential format');
  }
}

@MappableClass()
class GitCredentialUserPass extends GitCredential with GitCredentialUserPassMappable {
  const GitCredentialUserPass({
    required this.username,
    required this.password,
  });

  @MappableField(key: 'username')
  final String username;

  @MappableField(key: 'password')
  final String password;
}

@MappableClass()
class GitRepositoryMetadata with GitRepositoryMetadataMappable {
  const GitRepositoryMetadata({
    required this.url,
    required this.branch,
    this.credential,
    required this.lastSync,
    required this.commitHash,
    required this.gpgIds,
    required this.numberOfVaults,
  });

  @MappableField(key: 'url')
  final String url;

  @MappableField(key: 'branch')
  final String branch;

  @MappableField(key: 'credential')
  final GitCredential? credential;

  @MappableField(key: 'lastSync')
  final String lastSync;

  @MappableField(key: 'commitHash')
  final String commitHash;

  @MappableField(key: 'gpgIds')
  final IList<String> gpgIds;

  @MappableField(key: 'numberOfVaults')
  final int numberOfVaults;
}

@MappableClass()
class Vault with VaultMappable {
  const Vault({
    required this.raw,
    required this.vault,
    required this.username,
    required this.websites,
    required this.otpauth,
    required this.customFields,
  });

  @MappableField(key: 'raw')
  final String raw;

  @MappableField(key: 'vault')
  final String vault;

  @MappableField(key: 'username')
  final String username;

  @MappableField(key: 'websites')
  final IList<String> websites;

  @MappableField(key: 'otpauth')
  final OtpAuth? otpauth;

  @MappableField(key: '')
  final IList<MapEntry<String, String>> customFields;
}

@MappableClass()
sealed class OtpAuth with OtpAuthMappable {
  const OtpAuth({
    required this.raw,
    required this.label,
    required this.secret,
    required this.issuer,
    required this.digits,
    required this.algorithm,
  });

  @MappableField(key: 'raw')
  final String raw;

  @MappableField(key: 'label')
  final String label;

  @MappableField(key: 'secret')
  final String secret;

  @MappableField(key: 'issuer')
  final String issuer;

  @MappableField(key: 'digits')
  final int digits;

  @MappableField(key: 'algorithm')
  final String algorithm;

  static OtpAuth? tryParse(String uriString) {
    try {
      return OtpAuth.parse(uriString);
    } catch (e) {
      print(e);
      return null;
    }
  }

  static OtpAuth parse(String uriString) {
    final uri = Uri.parse(uriString);

    if (uri.scheme != 'otpauth') {
      throw 'invalid scheme: ${uri.scheme}';
    }

    final type = uri.host.toLowerCase();
    if (type != "totp" && type != "hotp") {
      throw 'invalid host: $type';
    }

    final secret = uri.queryParameters['secret'];
    if (secret == null || secret.isEmpty) {
      throw 'secret required';
    }

    final issuer = uri.queryParameters['issuer'] ?? '';
    final label = Uri.decodeComponent(uri.path.substring(1));
    final digits = int.tryParse(uri.queryParameters['digits'] ?? '') ?? 6;
    final algorithm = uri.queryParameters['algorithm']?.toUpperCase() ?? 'SHA1';

    if (type == 'totp') {
      final period = int.tryParse(uri.queryParameters['period'] ?? '') ?? 30;
      return OtpAuthTotp(
        raw: uriString,
        label: label,
        secret: secret,
        issuer: issuer,
        digits: digits,
        algorithm: algorithm,
        period: period,
      );
    } else if (type == 'hotp') {
      final counterStr = uri.queryParameters['counter'];
      if (counterStr == null) {
        throw 'counter required';
      }
      final counter = int.tryParse(counterStr);
      if (counter == null) {
        throw 'invalid counter: $counterStr';
      }
      return OtpAuthHotp(
        raw: uriString,
        label: label,
        secret: secret,
        issuer: issuer,
        digits: digits,
        algorithm: algorithm,
        counter: counter,
      );
    } else {
      throw 'invalid type: $type';
    }
  }
}


@MappableClass()
class OtpAuthTotp extends OtpAuth with OtpAuthTotpMappable {
  const OtpAuthTotp({
    required super.raw,
    required super.label,
    required super.secret,
    required super.issuer,
    required super.digits,
    required super.algorithm,
    required this.period,
  });

  @MappableField(key: 'period')
  final int period;
}

@MappableClass()
class OtpAuthHotp extends OtpAuth with OtpAuthHotpMappable {
  const OtpAuthHotp({
    required super.raw,
    required super.label,
    required super.secret,
    required super.issuer,
    required super.digits,
    required super.algorithm,
    required this.counter,
  });

  @MappableField(key: 'counter')
  final int counter;
}
