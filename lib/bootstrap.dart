import 'package:pdfrx/pdfrx.dart';

import 'data/database.dart';
import 'data/storage.dart';
import 'demo_seed.dart';
import 'security/app_lock.dart';
import 'security/vault.dart';
import 'services/ai/ai_config.dart';

/// Storage locations, overridable so demo mode and tests never touch real data.
class StorageConfig {
  const StorageConfig({this.dbName = 'medi_archive.db', this.filesFolder = 'attachments'});
  final String dbName;
  final String filesFolder;

  static const real = StorageConfig();
  static const demo = StorageConfig(dbName: 'demo.db', filesFolder: 'demo_attachments');
}

/// Opens the key, encrypted file store and encrypted database, in that order.
/// Throws [VaultLockedException] if the key is unavailable but data exists.
Future<void> bootstrap({StorageConfig config = StorageConfig.real, KeyStore? keyStore, bool seedDemoData = false}) async {
  pdfrxFlutterInitialize();
  final store = keyStore ?? SecureKeyStore();
  // Plaintext data from before encryption existed is migrated below; only
  // data already encrypted makes a missing key fatal.
  final dbPath = await AppDb.pathFor(config.dbName);
  final hasEncryptedData = (await AppDb.exists(fileName: config.dbName) && !await AppDb.isPlaintext(dbPath)) ||
      await FileStore.hasEncryptedFiles(folder: config.filesFolder);
  final vault = await Vault.open(keyStore: store, hasExistingData: hasEncryptedData);
  await FileStore.purgeTempPlainFiles();
  await FileStore.init(folder: config.filesFolder, vault: vault);
  await AppDb.init(fileName: config.dbName, password: vault.databasePassword);
  await AppLock.init(store);
  await AiSettings.init(store);
  if (seedDemoData) await seedDemo();
}
