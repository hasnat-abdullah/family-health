import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate, IOException;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_config.dart';

enum AiErrorKind { auth, quota, rateLimited, overloaded, network, timeout, modelNotFound, tooLarge, badRequest, refused, truncated, invalidResponse, unsupported, cancelled }

/// A failed AI call, with a message fit to show. The on-device reading and the
/// original file are never affected by one of these.
class AiException implements Exception {
  const AiException(this.kind, {this.detail, this.retryAfter});
  final AiErrorKind kind;

  /// The provider's own words (no keys), for the "details" line.
  final String? detail;
  final Duration? retryAfter;

  /// The user fixes this in settings rather than by trying again.
  bool get needsSettings => const {AiErrorKind.auth, AiErrorKind.quota, AiErrorKind.modelNotFound}.contains(kind);

  String get message => switch (kind) {
    AiErrorKind.auth => 'The API key was rejected. Check it in AI reading settings.',
    AiErrorKind.quota => 'Your AI account is out of credit or quota. Check billing with the provider.',
    AiErrorKind.rateLimited =>
      'The AI provider is limiting requests right now.${retryAfter == null ? ' Try again in a minute.' : ' Try again in about ${retryAfter!.inSeconds < 90 ? '${retryAfter!.inSeconds} seconds' : '${retryAfter!.inMinutes} minutes'}.'}',
    AiErrorKind.overloaded => 'The AI service is busy or having problems. Try again shortly.',
    AiErrorKind.network => "Couldn't reach the AI service. Check your connection, or that your local model is running.",
    AiErrorKind.timeout => 'The AI took too long to answer. Try again, or use a faster model.',
    AiErrorKind.modelNotFound => "That model isn't available on your account. Pick another in AI reading settings.",
    AiErrorKind.tooLarge => 'This document is too large for the AI. Try fewer pages.',
    AiErrorKind.badRequest => 'The AI service rejected the request.',
    AiErrorKind.refused => 'The AI declined to read this document.',
    AiErrorKind.truncated => 'This document was too long for the AI to finish.',
    AiErrorKind.invalidResponse => "The AI's answer couldn't be understood, so none of it was used.",
    AiErrorKind.unsupported => 'This file could not be prepared for the AI.',
    AiErrorKind.cancelled => 'Cancelled.',
  };

  @override
  String toString() => 'AiException($kind${detail == null ? '' : ': $detail'})';
}

/// Lets the user stop a call, including one waiting to retry.
class AiCancelToken {
  final _done = Completer<void>();
  http.Client? _active;

  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (isCancelled) return;
    _done.complete();
    _active?.close();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const AiException(AiErrorKind.cancelled);
  }
}

class AiImage {
  const AiImage(this.bytes, this.mime);
  final Uint8List bytes;
  final String mime;
  String get base64 => base64Encode(bytes);
}

class AiRequest {
  const AiRequest({required this.system, required this.prompt, this.images = const [], required this.schema, this.maxTokens = 16000});
  final String system;
  final String prompt;
  final List<AiImage> images;
  final Map<String, Object?> schema;
  final int maxTokens;
}

/// Sends JSON with timeouts and retries, and turns every failure into an [AiException].
class AiTransport {
  AiTransport({http.Client Function()? clientFactory, Future<void> Function(Duration)? sleep, this.maxAttempts = 3, this.timeout = const Duration(minutes: 4)})
    : _clientFactory = clientFactory ?? http.Client.new,
      _sleep = sleep ?? Future<void>.delayed;

  final http.Client Function() _clientFactory;
  final Future<void> Function(Duration) _sleep;
  final int maxAttempts;
  final Duration timeout;
  final _random = Random();

  /// Longest wait we sit through for the user; beyond this we tell them instead.
  static const maxWait = Duration(seconds: 30);

  /// Removes [secrets] from anything that may reach the screen.
  static String scrub(String text, Iterable<String> secrets) {
    var out = text;
    for (final s in secrets.where((s) => s.length > 4)) {
      out = out.replaceAll(s, '•••');
    }
    return out.length > 240 ? '${out.substring(0, 240)}…' : out;
  }

  Future<Map<String, Object?>> postJson(Uri url, Map<String, String> headers, Map<String, Object?> body, {AiCancelToken? cancel, Set<String> secrets = const {}}) async {
    final payload = jsonEncode(body);
    for (var attempt = 1; ; attempt++) {
      try {
        return await _once((client) => client.post(url, headers: {'content-type': 'application/json', ...headers}, body: payload), cancel, secrets);
      } on AiException catch (e) {
        final transient = const {AiErrorKind.rateLimited, AiErrorKind.overloaded, AiErrorKind.network}.contains(e.kind);
        if (!transient || attempt >= maxAttempts) rethrow;
        // Exponential backoff with jitter unless the server said how long to wait.
        final wait = e.retryAfter ?? Duration(milliseconds: (1000 * pow(2, attempt - 1)).toInt() + _random.nextInt(500));
        if (wait > maxWait) rethrow;
        await Future.any([_sleep(wait), if (cancel != null) cancel.whenCancelled]);
        cancel?.throwIfCancelled();
      }
    }
  }

  Future<Map<String, Object?>> getJson(Uri url, Map<String, String> headers, {AiCancelToken? cancel, Set<String> secrets = const {}}) =>
      _once((client) => client.get(url, headers: headers), cancel, secrets);

  Future<Map<String, Object?>> _once(Future<http.Response> Function(http.Client) send, AiCancelToken? cancel, Set<String> secrets) async {
    cancel?.throwIfCancelled();
    final client = _clientFactory();
    cancel?._active = client;
    try {
      final response = await send(client).timeout(timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          throw const AiException(AiErrorKind.invalidResponse, detail: 'The server did not return JSON.');
        }
        if (decoded is! Map<String, Object?>) throw const AiException(AiErrorKind.invalidResponse, detail: 'Unexpected reply shape.');
        return decoded;
      }
      throw classify(response.statusCode, utf8.decode(response.bodyBytes, allowMalformed: true), response.headers['retry-after'], secrets);
    } on TimeoutException {
      throw const AiException(AiErrorKind.timeout);
    } on IOException catch (e) {
      if (cancel?.isCancelled ?? false) throw const AiException(AiErrorKind.cancelled);
      throw AiException(AiErrorKind.network, detail: scrub('$e', secrets));
    } on http.ClientException catch (e) {
      if (cancel?.isCancelled ?? false) throw const AiException(AiErrorKind.cancelled);
      throw AiException(AiErrorKind.network, detail: scrub(e.message, secrets));
    } finally {
      client.close();
    }
  }

  @visibleForTesting
  static AiException classify(int status, String body, String? retryAfter, Set<String> secrets) {
    var text = body;
    var code = '';
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      if (err is Map) {
        text = '${err['message'] ?? body}';
        code = '${err['code'] ?? ''} ${err['type'] ?? ''} ${err['status'] ?? ''}'.toLowerCase();
      } else if (err is String) {
        text = err;
      }
    } on FormatException {
      // Plain-text or HTML error page.
    }
    final detail = scrub(text, secrets);
    final lower = '$code ${text.toLowerCase()}';
    final wait = _parseRetryAfter(retryAfter);
    if (status == 401 || status == 403 || lower.contains('api_key_invalid') || lower.contains('api key not valid')) {
      return AiException(AiErrorKind.auth, detail: detail);
    }
    if (status == 402 || lower.contains('insufficient_quota') || lower.contains('billing') || lower.contains('credit balance')) {
      return AiException(AiErrorKind.quota, detail: detail);
    }
    if (status == 404) return AiException(AiErrorKind.modelNotFound, detail: detail);
    if (status == 413 || (status == 400 && RegExp(r'too large|too long|exceeds the maximum|maximum context|context length').hasMatch(lower))) {
      return AiException(AiErrorKind.tooLarge, detail: detail);
    }
    if (status == 408 || status == 429) return AiException(AiErrorKind.rateLimited, detail: detail, retryAfter: wait);
    if (status >= 500) return AiException(AiErrorKind.overloaded, detail: detail, retryAfter: wait);
    return AiException(AiErrorKind.badRequest, detail: 'HTTP $status: $detail');
  }

  static Duration? _parseRetryAfter(String? header) {
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds != null) return Duration(seconds: seconds);
    try {
      final d = HttpDate.parse(header).difference(DateTime.now());
      return d.isNegative ? Duration.zero : d;
    } on Object {
      return null;
    }
  }
}

/// One provider's API. Returns the model's JSON text.
abstract class AiBackend {
  Future<String> complete(AiRequest request, {AiCancelToken? cancel});

  /// Model names the server offers, where it can say.
  Future<List<String>> listModels({AiCancelToken? cancel}) async => const [];

  static AiBackend from(AiSettings s, AiProvider p, {AiTransport? transport}) {
    final key = s.perProvider[p]?.apiKey.trim() ?? '';
    final model = s.modelFor(p);
    final base = s.baseUrlFor(p);
    return switch (p) {
      AiProvider.gemini => GeminiBackend(apiKey: key, model: model, baseUrl: base, transport: transport),
      AiProvider.anthropic => AnthropicBackend(apiKey: key, model: model, baseUrl: base, transport: transport),
      AiProvider.openai => OpenAiBackend(apiKey: key, model: model, baseUrl: base, transport: transport),
      AiProvider.local => OpenAiBackend(apiKey: key, model: model, baseUrl: base, local: true, transport: transport ?? AiTransport(timeout: const Duration(minutes: 10))),
      AiProvider.off => throw StateError('AI reading is off'),
    };
  }
}

/// Claude Messages API. Structured outputs guarantee the JSON shape; sampling
/// parameters and forced tool choice are rejected by current models, so neither is sent.
class AnthropicBackend implements AiBackend {
  AnthropicBackend({required this.apiKey, required this.model, required this.baseUrl, AiTransport? transport}) : _http = transport ?? AiTransport();
  final String apiKey;
  final String model;
  final String baseUrl;
  final AiTransport _http;

  // Re-runs a safety-classifier refusal on another model, which matters here
  // because medical documents can trip a classifier by mistake. Haiku and older
  // models have no server-side fallback.
  bool get _hasFallback => RegExp(r'^claude-(fable|opus|sonnet)-5').hasMatch(model);

  Map<String, String> _headers({required bool fallback}) => {
    'x-api-key': apiKey,
    'anthropic-version': '2026-10-21',
    if (fallback) 'anthropic-beta': 'server-side-fallback-2026-07-01',
  };

  @override
  Future<String> complete(AiRequest r, {AiCancelToken? cancel}) async {
    Map<String, Object?> body(bool fallback) => {
      'model': model,
      'max_tokens': r.maxTokens,
      'system': r.system,
      'messages': [
        {
          'role': 'user',
          'content': [
            for (final i in r.images)
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': i.mime, 'data': i.base64},
              },
            {'type': 'text', 'text': r.prompt},
          ],
        },
      ],
      'output_config': {
        'effort': 'high',
        'format': {'type': 'json_schema', 'schema': r.schema},
      },
      if (fallback) 'fallbacks': 'default',
    };
    final url = Uri.parse('$baseUrl/messages');
    Map<String, Object?> reply;
    try {
      reply = await _http.postJson(url, _headers(fallback: _hasFallback), body(_hasFallback), cancel: cancel, secrets: {apiKey});
    } on AiException catch (e) {
      // Not every organisation has the beta; reading must still work without it.
      if (!_hasFallback || e.kind != AiErrorKind.badRequest || !(e.detail ?? '').contains(RegExp('anthropic-beta|fallbacks'))) rethrow;
      reply = await _http.postJson(url, _headers(fallback: false), body(false), cancel: cancel, secrets: {apiKey});
    }
    switch (reply['stop_reason']) {
      case 'refusal':
        throw const AiException(AiErrorKind.refused);
      case 'max_tokens':
        throw const AiException(AiErrorKind.truncated);
    }
    final text = [
      for (final b in reply['content'] as List? ?? const [])
        if (b is Map && b['type'] == 'text') b['text'] as String,
    ].join();
    if (text.trim().isEmpty) throw const AiException(AiErrorKind.invalidResponse, detail: 'Empty reply.');
    return text;
  }

  @override
  Future<List<String>> listModels({AiCancelToken? cancel}) async => const [];
}

/// OpenAI Chat Completions, which local servers (Ollama, LM Studio, llama.cpp,
/// vLLM) also speak.
class OpenAiBackend implements AiBackend {
  OpenAiBackend({required this.apiKey, required this.model, required this.baseUrl, this.local = false, AiTransport? transport}) : _http = transport ?? AiTransport();
  final String apiKey;
  final String model;
  final String baseUrl;
  final bool local;
  final AiTransport _http;

  Map<String, String> get _headers => {if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey'};

  @override
  Future<String> complete(AiRequest r, {AiCancelToken? cancel}) async {
    final url = Uri.parse('$baseUrl/chat/completions');
    Map<String, Object?> body({required bool schema}) => {
      'model': model,
      // Local servers mostly keep the older name; cloud models accept only the newer one.
      if (local) 'max_tokens': r.maxTokens else 'max_completion_tokens': r.maxTokens,
      if (local) 'temperature': 0,
      'messages': [
        {'role': 'system', 'content': schema ? r.system : '${r.system}\n\nReply with only one JSON object matching this JSON Schema:\n${jsonEncode(r.schema)}'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': r.prompt},
            for (final i in r.images)
              {
                'type': 'image_url',
                'image_url': {'url': 'data:${i.mime};base64,${i.base64}'},
              },
          ],
        },
      ],
      if (schema)
        'response_format': {
          'type': 'json_schema',
          'json_schema': {'name': 'document', 'strict': true, 'schema': r.schema},
        },
    };
    Map<String, Object?> reply;
    try {
      reply = await _http.postJson(url, _headers, body(schema: true), cancel: cancel, secrets: {apiKey});
    } on AiException catch (e) {
      // Some local servers don't know json_schema. Ask in words instead; the
      // reply is validated the same way.
      if (!local || e.kind != AiErrorKind.badRequest) rethrow;
      reply = await _http.postJson(url, _headers, body(schema: false), cancel: cancel, secrets: {apiKey});
    }
    final choices = reply['choices'] as List? ?? const [];
    if (choices.isEmpty) throw const AiException(AiErrorKind.invalidResponse, detail: 'No choices in reply.');
    final choice = choices.first as Map;
    final message = choice['message'] as Map? ?? const {};
    if (message['refusal'] != null) throw AiException(AiErrorKind.refused, detail: '${message['refusal']}');
    switch (choice['finish_reason']) {
      case 'length':
        throw const AiException(AiErrorKind.truncated);
      case 'content_filter':
        throw const AiException(AiErrorKind.refused);
    }
    final text = message['content'];
    if (text is! String || text.trim().isEmpty) throw const AiException(AiErrorKind.invalidResponse, detail: 'Empty reply.');
    return text;
  }

  @override
  Future<List<String>> listModels({AiCancelToken? cancel}) async {
    final reply = await _http.getJson(Uri.parse('$baseUrl/models'), _headers, cancel: cancel, secrets: {apiKey});
    return [
      for (final m in reply['data'] as List? ?? const [])
        if (m is Map && m['id'] is String) m['id'] as String,
    ]..sort();
  }
}

/// Gemini generateContent. The key travels in a header, so it can't end up in
/// a URL shown in an error.
class GeminiBackend implements AiBackend {
  GeminiBackend({required this.apiKey, required this.model, required this.baseUrl, AiTransport? transport}) : _http = transport ?? AiTransport();
  final String apiKey;
  final String model;
  final String baseUrl;
  final AiTransport _http;

  /// Gemini's `responseSchema` is an OpenAPI subset: `nullable: true` rather than
  /// type arrays, and no `additionalProperties`.
  @visibleForTesting
  static Map<String, Object?> toGeminiSchema(Map<String, Object?> s) {
    final out = <String, Object?>{};
    for (final e in s.entries) {
      switch (e.key) {
        case 'additionalProperties':
          break;
        case 'type' when e.value is List:
          final types = (e.value as List).cast<String>();
          out['type'] = types.firstWhere((t) => t != 'null');
          if (types.contains('null')) out['nullable'] = true;
        case 'properties':
          out['properties'] = {for (final p in (e.value as Map<String, Object?>).entries) p.key: toGeminiSchema(p.value as Map<String, Object?>)};
        case 'items':
          out['items'] = toGeminiSchema(e.value as Map<String, Object?>);
        case 'enum':
          out['enum'] = [for (final v in e.value as List) ?v];
        default:
          out[e.key] = e.value;
      }
    }
    return out;
  }

  @override
  Future<String> complete(AiRequest r, {AiCancelToken? cancel}) async {
    final reply = await _http.postJson(
      Uri.parse('$baseUrl/models/$model:generateContent'),
      {'x-goog-api-key': apiKey},
      {
        'systemInstruction': {
          'parts': [
            {'text': r.system},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              for (final i in r.images)
                {
                  'inlineData': {'mimeType': i.mime, 'data': i.base64},
                },
              {'text': r.prompt},
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0,
          'maxOutputTokens': r.maxTokens,
          'responseMimeType': 'application/json',
          'responseSchema': toGeminiSchema(r.schema),
        },
      },
      cancel: cancel,
      secrets: {apiKey},
    );
    final blocked = (reply['promptFeedback'] as Map?)?['blockReason'];
    if (blocked != null) throw AiException(AiErrorKind.refused, detail: '$blocked');
    final candidates = reply['candidates'] as List? ?? const [];
    if (candidates.isEmpty) throw const AiException(AiErrorKind.invalidResponse, detail: 'No candidates in reply.');
    final candidate = candidates.first as Map;
    final finish = candidate['finishReason'];
    if (finish == 'MAX_TOKENS') throw const AiException(AiErrorKind.truncated);
    if (finish != null && finish != 'STOP') throw AiException(AiErrorKind.refused, detail: '$finish');
    final parts = (candidate['content'] as Map?)?['parts'] as List? ?? const [];
    final text = parts.map((p) => (p as Map)['text'] as String? ?? '').join();
    if (text.trim().isEmpty) throw const AiException(AiErrorKind.invalidResponse, detail: 'Empty reply.');
    return text;
  }

  @override
  Future<List<String>> listModels({AiCancelToken? cancel}) async => const [];
}
