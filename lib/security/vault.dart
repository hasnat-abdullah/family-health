import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the master key lives. Real devices use the Keychain / Keystore;
/// tests inject [MemoryKeyStore].
abstract class KeyStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> delete(String name);
}

class SecureKeyStore implements KeyStore {
  static const _storage = FlutterSecureStorage(
    // Readable after the first unlock since boot; stays on this device
    // (and in encrypted device backups on iOS).
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    // The data-protection keychain needs a signed app with a team ID; the
    // login keychain works for locally built apps too.
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock, usesDataProtectionKeychain: false),
  );

  @override
  Future<String?> read(String name) => _storage.read(key: name);
  @override
  Future<void> write(String name, String value) => _storage.write(key: name, value: value);
  @override
  Future<void> delete(String name) => _storage.delete(key: name);
}

class MemoryKeyStore implements KeyStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String name) async => values[name];
  @override
  Future<void> write(String name, String value) async => values[name] = value;
  @override
  Future<void> delete(String name) async => values.remove(name);
}

/// The key is missing but encrypted data exists. We must not create a new
/// key (that would make the existing data unreadable for good).
class VaultLockedException implements Exception {
  const VaultLockedException();
  @override
  String toString() => 'The encryption key for your records could not be read from the secure keychain.';
}

class WrongPasswordException implements Exception {
  const WrongPasswordException();
  @override
  String toString() => 'Wrong password, or the file is damaged.';
}

/// Holds the device master key and encrypts data at rest.
///
/// * The database is encrypted by SQLCipher (AES-256) with [databasePassword].
/// * Original files are encrypted with AES-256-GCM under a separate sub-key.
/// * Both sub-keys are derived from one random 256-bit master key with HKDF,
///   and the master key is kept only in the platform keychain.
class Vault {
  Vault._(this.keyStore, this._dbKey, this._fileKey);

  static late Vault instance;
  static const _masterKeyName = 'medi_archive.master_key.v1';
  static final _aes = AesGcm.with256bits();

  final KeyStore keyStore;
  final List<int> _dbKey;
  final SecretKey _fileKey;

  /// Loads the master key, or creates one when there is no existing data.
  /// [hasExistingData]: encrypted data exists, so the key must already be there.
  static Future<Vault> open({required KeyStore keyStore, required bool hasExistingData}) async {
    var encoded = await keyStore.read(_masterKeyName);
    if (encoded == null) {
      if (hasExistingData) throw const VaultLockedException();
      encoded = base64Encode(randomBytes(32));
      await keyStore.write(_masterKeyName, encoded);
      // Read back so we never use a key that wasn't persisted.
      if (await keyStore.read(_masterKeyName) != encoded) {
        throw StateError('Could not save the encryption key to the secure keychain.');
      }
    }
    final master = SecretKey(base64Decode(encoded));
    Future<List<int>> derive(String purpose) async => (await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
            .deriveKey(secretKey: master, nonce: utf8.encode('medi_archive'), info: utf8.encode(purpose)))
        .extractBytes();
    final vault = Vault._(keyStore, await derive('sqlcipher'), SecretKey(await derive('files')));
    instance = vault;
    return vault;
  }

  /// SQLCipher passphrase (hex of a derived 256-bit key).
  String get databasePassword => _dbKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ---- Files at rest: MAGIC | nonce(12) | ciphertext | mac(16)

  static final _fileMagic = ascii.encode('MAF1');

  static bool isEncryptedFile(List<int> bytes) =>
      bytes.length >= 4 && _startsWith(bytes, _fileMagic);

  Future<Uint8List> encryptFile(List<int> plain) async {
    final box = await _aes.encrypt(plain, secretKey: _fileKey, nonce: _aes.newNonce(), aad: _fileMagic);
    return _concat([_fileMagic, box.nonce, box.cipherText, box.mac.bytes]);
  }

  Future<Uint8List> decryptFile(List<int> data) async {
    if (!isEncryptedFile(data)) return Uint8List.fromList(data); // pre-encryption file
    final box = SecretBox(
      data.sublist(16, data.length - 16),
      nonce: data.sublist(4, 16),
      mac: Mac(data.sublist(data.length - 16)),
    );
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: _fileKey, aad: _fileMagic));
  }

  // ---- Password-protected backups
  // MAGIC(4) | version(1) | iterations(u32 BE) | salt(16) | nonce(12) | ciphertext | mac(16)
  // The header is authenticated as associated data.

  static final _backupMagic = ascii.encode('MABK');
  static const backupIterations = 310000;

  // Pure-Dart implementations: these run in a background isolate, where the
  // platform-channel (native) implementations are unavailable.
  static final _isolateAes = DartAesGcm.with256bits();

  static bool isEncryptedBackup(List<int> bytes) => bytes.length > 37 && _startsWith(bytes, _backupMagic);

  // Key derivation is deliberately slow (~1s), so it runs off the UI isolate.
  static Future<Uint8List> encryptWithPassword(List<int> plain, String password, {int iterations = backupIterations}) =>
      Isolate.run(() => _encryptWithPassword(plain, password, iterations));

  static Future<Uint8List> decryptWithPassword(List<int> data, String password) =>
      Isolate.run(() => _decryptWithPassword(data, password));

  static Future<Uint8List> _encryptWithPassword(List<int> plain, String password, int iterations) async {
    final salt = randomBytes(16);
    final header = _concat([
      _backupMagic,
      [1],
      (ByteData(4)..setUint32(0, iterations)).buffer.asUint8List(),
      salt,
    ]);
    final key = await _passwordKey(password, salt, iterations);
    final box = await _isolateAes.encrypt(plain, secretKey: key, nonce: _isolateAes.newNonce(), aad: header);
    return _concat([header, box.nonce, box.cipherText, box.mac.bytes]);
  }

  static Future<Uint8List> _decryptWithPassword(List<int> data, String password) async {
    if (!isEncryptedBackup(data) || data[4] != 1) throw const FormatException('Not an encrypted Medi Archive backup.');
    final iterations = ByteData.sublistView(Uint8List.fromList(data.sublist(5, 9))).getUint32(0);
    final header = data.sublist(0, 25);
    final key = await _passwordKey(password, data.sublist(9, 25), iterations);
    try {
      final box = SecretBox(data.sublist(37, data.length - 16), nonce: data.sublist(25, 37), mac: Mac(data.sublist(data.length - 16)));
      return Uint8List.fromList(await _isolateAes.decrypt(box, secretKey: key, aad: header));
    } on SecretBoxAuthenticationError {
      throw const WrongPasswordException();
    }
  }

  static Future<SecretKey> _passwordKey(String password, List<int> salt, int iterations) =>
      DartPbkdf2(macAlgorithm: DartHmac(const DartSha256()), iterations: iterations, bits: 256, pausePeriod: Duration.zero)
          .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  // ---- helpers

  static final _random = Random.secure();
  static Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static Uint8List _concat(List<List<int>> parts) {
    final out = BytesBuilder(copy: false);
    for (final p in parts) {
      out.add(p);
    }
    return out.toBytes();
  }
}
