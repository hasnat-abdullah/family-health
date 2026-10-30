import 'package:flutter/material.dart';

import '../services/ai/ai_client.dart';
import '../services/ai/ai_config.dart';
import '../services/ai/extraction_prompt.dart';
import '../widgets/common.dart';

/// Asks once per cloud provider before any document leaves the device.
Future<bool> ensureAiConsent(BuildContext context) async {
  final s = AiSettings.instance;
  final p = s.provider;
  if (!p.isCloud || s.consented.contains(p)) return true;
  final ok = await confirm(
    context,
    title: 'Send documents to ${p.label}?',
    message:
        'When you use AI reading, the pages of that document, including any name and details printed on them, go to ${p.label} and are handled under your account\'s terms with them.\n\n'
        'Nothing else is sent: not your other records, family names or past results. You check everything before it is saved.',
    action: 'Agree',
  );
  if (!ok) return false;
  s.consented.add(p);
  await s.save();
  return true;
}

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  final _settings = AiSettings.instance;
  late AiProvider _provider = _settings.provider;
  late bool _sendImages = _settings.sendImages;
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _url = TextEditingController();
  bool _showKey = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  List<String> _serverModels = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final s = _settings.perProvider[_provider];
    _key.text = s?.apiKey ?? '';
    _model.text = s?.model ?? '';
    _url.text = s?.baseUrl ?? '';
    _testResult = null;
    _serverModels = const [];
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _url.dispose();
    super.dispose();
  }

  void _store() {
    _settings
      ..provider = _provider
      ..sendImages = _sendImages;
    final s = _settings.perProvider[_provider];
    s
      ?..apiKey = _key.text.trim()
      ..model = _model.text.trim()
      ..baseUrl = _url.text.trim();
  }

  Future<void> _save() async {
    _store();
    final problem = _provider == AiProvider.off ? null : _settings.configProblem(_provider);
    if (problem != null) {
      showMessage(context, problem);
      return;
    }
    await _settings.save();
    if (mounted) Navigator.pop(context);
  }

  /// A tiny real request, with no medical data, so a bad key or model shows up
  /// here rather than in the middle of reading a report.
  Future<void> _test() async {
    _store();
    final problem = _settings.configProblem(_provider);
    if (problem != null) {
      setState(() {
        _testOk = false;
        _testResult = problem;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final backend = AiBackend.from(_settings, _provider);
      await backend.complete(const AiRequest(system: 'Reply with JSON only.', prompt: pingPrompt, schema: pingSchema, maxTokens: 1024));
      final models = _provider == AiProvider.local ? await backend.listModels().catchError((_) => const <String>[]) : const <String>[];
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testResult = 'Connected to ${_provider.label} using ${_settings.modelFor(_provider)}.';
        _serverModels = models;
      });
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = [e.message, ?e.detail].join('\n');
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gap = SizedBox(height: 16);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final suggestions = {..._provider.models, ..._serverModels}.toList();
    final on = _provider != AiProvider.off;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI document reading'),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 12), child: FilledButton(onPressed: _save, child: const Text('Save'))),
        ],
      ),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'AI can read a report or prescription for you: results, medicines, doctor and dates. It is off unless you turn it on. '
              'Every value is compared with what your device read on its own, and you review it before saving.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            gap,
            DropdownButtonFormField<AiProvider>(
              key: ValueKey(_provider),
              initialValue: _provider,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: [for (final p in AiProvider.values) DropdownMenuItem(value: p, child: Text(p.label))],
              onChanged: (p) {
                if (p == null) return;
                setState(() {
                  _provider = p;
                  _load();
                });
              },
            ),
            if (on) ...[
              gap,
              Card(
                child: ListTile(
                  leading: Icon(_provider.isCloud ? Icons.cloud_outlined : Icons.computer_rounded),
                  title: Text(_provider.isCloud ? 'Pages are sent to ${_provider.label}' : 'Pages stay on your own machine or network'),
                  subtitle: Text(_provider.isCloud ? 'Only the document you are reading, and only with your API key. You are asked once before the first one.' : 'Works with Ollama, LM Studio or any OpenAI-compatible server. Use a vision model to send page images.'),
                ),
              ),
              if (_provider != AiProvider.local || _key.text.isNotEmpty) ...[
                gap,
                TextField(
                  controller: _key,
                  obscureText: !_showKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'API key',
                    helperText: 'Kept in the secure keychain. Never included in backups.',
                    suffixIcon: IconButton(
                      tooltip: _showKey ? 'Hide' : 'Show',
                      icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _showKey = !_showKey),
                    ),
                  ),
                ),
                if (_provider.keyUrl.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SelectableText('Get a key: ${_provider.keyUrl}', style: muted),
                ],
              ],
              if (_provider == AiProvider.local) ...[
                gap,
                TextField(
                  controller: _url,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: 'Server address', hintText: _provider.defaultBaseUrl, helperText: 'Ollama: port 11434. LM Studio: port 1234. From a phone, use your computer\'s network address.'),
                ),
              ],
              gap,
              TextField(
                controller: _model,
                autocorrect: false,
                decoration: InputDecoration(labelText: 'Model', hintText: _provider.models.firstOrNull ?? 'e.g. a vision model you have installed'),
                onChanged: (_) => setState(() {}),
              ),
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final m in suggestions)
                    ChoiceChip(label: Text(m), selected: _model.text.trim() == m || (_model.text.trim().isEmpty && m == suggestions.first), onSelected: (_) => setState(() => _model.text = m)),
                ]),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Send page images'),
                subtitle: const Text('Best accuracy. Turn off to send only text read on this device (for text-only models, or to share less); tables and handwriting then read much less well.'),
                value: _sendImages,
                onChanged: (v) => setState(() => _sendImages = v),
              ),
              const SizedBox(height: 8),
              Row(children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.wifi_tethering_rounded),
                  label: const Text('Test connection'),
                ),
              ]),
              if (_testResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(_testOk ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded, color: _testOk ? theme.colorScheme.primary : theme.colorScheme.error, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: SelectableText(_testResult!)),
                  ]),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
