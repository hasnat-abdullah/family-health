import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:family_health/security/vault.dart';

void main() {
  test('creates and persists a key on first run, reuses it after', () async {
    final store = MemoryKeyStore();
    final a = await Vault.open(keyStore: store, hasExistingData: false);
    final b = await Vault.open(keyStore: store, hasExistingData: true);
    expect(a.databasePassword, b.databasePassword);
    expect(a.databasePassword, hasLength(64));
  });

  test('never replaces a missing key when data already exists', () async {
    expect(() => Vault.open(keyStore: MemoryKeyStore(), hasExistingData: true), throwsA(isA<VaultLockedException>()));
  });

  test('file encryption round trip, tamper detection, legacy passthrough', () async {
    final vault = await Vault.open(keyStore: MemoryKeyStore(), hasExistingData: false);
    final plain = utf8.encode('Hemoglobin 10.8 g/dL');
    final enc = await vault.encryptFile(plain);
    expect(Vault.isEncryptedFile(enc), isTrue);
    expect(utf8.decode(enc, allowMalformed: true), isNot(contains('Hemoglobin')));
    expect(await vault.decryptFile(enc), plain);

    final tampered = [...enc]..[20] ^= 1;
    await expectLater(vault.decryptFile(tampered), throwsA(anything));

    // A different device key cannot read it.
    final other = await Vault.open(keyStore: MemoryKeyStore(), hasExistingData: false);
    await expectLater(other.decryptFile(enc), throwsA(anything));

    // Files saved before encryption existed are returned as-is.
    expect(await vault.decryptFile(plain), plain);
  });

  test('password backups', () async {
    final data = utf8.encode('zip bytes');
    final sw = Stopwatch()..start();
    final enc = await Vault.encryptWithPassword(data, 'correct horse');
    // ignore: avoid_print
    print('PBKDF2 ${Vault.backupIterations} iterations + AES: ${sw.elapsedMilliseconds} ms');
    expect(Vault.isEncryptedBackup(enc), isTrue);
    expect(await Vault.decryptWithPassword(enc, 'correct horse'), data);
    await expectLater(Vault.decryptWithPassword(enc, 'wrong'), throwsA(isA<WrongPasswordException>()));

    // Header (iteration count) is authenticated.
    final weakened = [...enc]..[8] ^= 1;
    await expectLater(Vault.decryptWithPassword(weakened, 'correct horse'), throwsA(isA<WrongPasswordException>()));
  });
}
