import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../security/vault.dart';

/// Where documents are sent for reading. [off] is the default: nothing leaves
/// the device until the user chooses a provider and agrees to it.
enum AiProvider {
  off('off', 'Off (on-device only)', '', [], ''),
  gemini('gemini', 'Google Gemini', 'https://generativelanguage.googleapis.com/v1beta', [
    'gemini-3.8-flash',
    'gemini-4-argon',
    'gemini-3.5-flash-lite',
  ], 'https://aistudio.google.com/apikey'),
  openai('openai', 'OpenAI', 'https://api.openai.com/v1', [
    'gpt-6.1-sol',
    'gpt-6-astra',
    'gpt-6.1-terra',
    'gpt-6-luna',
  ], 'https://platform.openai.com/api-keys'),
  anthropic('anthropic', 'Anthropic Claude', 'https://api.anthropic.com/v1', [
    'claude-opus-5-5',
    'claude-sonnet-5-5',
    'claude-haiku-5-5',
  ], 'https://platform.claude.com/settings/keys'),
  local('local', 'Local model', 'http://localhost:11434/v1', [], '');

  const AiProvider(this.id, this.label, this.defaultBaseUrl, this.models, this.keyUrl);
  final String id;
  final String label;
  final String defaultBaseUrl;

  /// Suggestions, recommended first. Any model name can be typed instead.
  final List<String> models;
  final String keyUrl;

  bool get isCloud => this != off && this != local;

  static AiProvider fromId(String? id) => values.firstWhere((p) => p.id == id, orElse: () => off);
}

class AiProviderSettings {
  AiProviderSettings({this.apiKey = '', this.model = '', this.baseUrl = ''});
  String apiKey;
  String model;
  String baseUrl;

  Map<String, Object?> toJson() => {'apiKey': apiKey, 'model': model, 'baseUrl': baseUrl};

  factory AiProviderSettings.fromJson(Map<String, Object?> m) => AiProviderSettings(
    apiKey: m['apiKey'] as String? ?? '',
    model: m['model'] as String? ?? '',
    baseUrl: m['baseUrl'] as String? ?? '',
  );
}

/// True for addresses that stay on this device or the home network. A key and
/// medical documents may only travel over plain http to these.
bool isPrivateHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1' || h.endsWith('.local')) return true;
  final parts = h.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.contains(null)) return false;
  final a = parts[0]!, b = parts[1]!;
  return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
}

/// AI reading settings. Everything, keys included, lives in the secure
/// keychain: never in the database, and so never in a backup.
class AiSettings {
  AiSettings._(this._store, this.provider, this.perProvider, this.sendImages, this.consented);

  static const _storeKey = 'medi_archive.ai.v1';
  static late AiSettings instance;

  /// Bumped on every save so screens can refresh.
  static final changed = ValueNotifier<int>(0);

  final KeyStore _store;
  AiProvider provider;
  final Map<AiProvider, AiProviderSettings> perProvider;

  /// Send page images. Off sends only text read on this device, which suits
  /// text-only local models and is more private, but reads tables less well.
  bool sendImages;

  /// Cloud providers the user has agreed to send documents to.
  final Set<AiProvider> consented;

  static Future<void> init(KeyStore store) async {
    final raw = await store.read(_storeKey);
    final m = raw == null ? const <String, Object?>{} : jsonDecode(raw) as Map<String, Object?>;
    final saved = m['providers'] as Map<String, Object?>? ?? const {};
    instance = AiSettings._(
      store,
      AiProvider.fromId(m['provider'] as String?),
      {
        for (final p in AiProvider.values)
          if (p != AiProvider.off)
            p: saved[p.id] == null
                ? AiProviderSettings()
                : AiProviderSettings.fromJson(saved[p.id] as Map<String, Object?>),
      },
      m['sendImages'] as bool? ?? true,
      {for (final id in (m['consented'] as List? ?? const [])) AiProvider.fromId(id as String)}..remove(AiProvider.off),
    );
  }

  AiProviderSettings get current => perProvider[provider] ?? AiProviderSettings();

  String modelFor(AiProvider p) {
    final s = perProvider[p]?.model.trim() ?? '';
    return s.isNotEmpty ? s : (p.models.isEmpty ? '' : p.models.first);
  }

  String baseUrlFor(AiProvider p) {
    final s = perProvider[p]?.baseUrl.trim() ?? '';
    return (s.isNotEmpty ? s : p.defaultBaseUrl).replaceFirst(RegExp(r'/+$'), '');
  }

  /// A provider is chosen and has what it needs to run.
  bool get enabled => configProblem(provider) == null && provider != AiProvider.off;

  /// What is missing or unsafe in [p]'s settings, or null if it can run.
  String? configProblem(AiProvider p) {
    if (p == AiProvider.off) return 'AI reading is off.';
    if (p.isCloud && (perProvider[p]?.apiKey.trim() ?? '').isEmpty) return 'Add your ${p.label} API key.';
    if (modelFor(p).isEmpty) return 'Enter a model name.';
    final uri = Uri.tryParse(baseUrlFor(p));
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return 'The server address is not valid.';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && isPrivateHost(uri.host))) {
      return 'Use https, or http only for an address on your own network.';
    }
    return null;
  }

  /// Shown on records this AI reads.
  String get sourceLabel => '${provider.label} · ${modelFor(provider)}';

  Future<void> save() async {
    await _store.write(
      _storeKey,
      jsonEncode({
        'provider': provider.id,
        'sendImages': sendImages,
        'consented': [for (final p in consented) p.id],
        'providers': {for (final e in perProvider.entries) e.key.id: e.value.toJson()},
      }),
    );
    changed.value++;
  }
}
