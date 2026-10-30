import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medi_archive/security/vault.dart';
import 'package:medi_archive/services/ai/ai_client.dart';
import 'package:medi_archive/services/ai/ai_config.dart';
import 'package:medi_archive/services/ai/extraction_prompt.dart';

const _request = AiRequest(system: 'sys', prompt: 'go', schema: pingSchema);

AiTransport _transport(MockClientHandler handler, {List<Duration>? slept, int attempts = 3}) => AiTransport(
  clientFactory: () => MockClient(handler),
  maxAttempts: attempts,
  sleep: (d) async => slept?.add(d),
);

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json', ...headers});

Future<AiException> _failure(Future<Object?> call) async {
  try {
    await call;
  } on AiException catch (e) {
    return e;
  }
  fail('Expected an AiException');
}

void main() {
  final geminiOk = {
    'candidates': [
      {
        'finishReason': 'STOP',
        'content': {
          'parts': [
            {'text': '{"ok":true}'},
          ],
        },
      },
    ],
  };

  group('request shapes', () {
    test('Anthropic: structured output, no sampling or forced tools, key in header', () async {
      late http.Request sent;
      final b = AnthropicBackend(
        apiKey: 'sk-secret',
        model: 'claude-opus-5-5',
        baseUrl: 'https://api.anthropic.com/v1',
        transport: _transport((r) async {
          sent = r;
          return _json({
            'stop_reason': 'end_turn',
            'content': [
              {'type': 'thinking', 'thinking': ''},
              {'type': 'text', 'text': '{"ok":true}'},
            ],
          });
        }),
      );
      final out = await b.complete(AiRequest(system: 's', prompt: 'p', schema: pingSchema, images: [AiImage(Uint8List.fromList([1, 2]), 'image/jpeg')]));
      expect(out, '{"ok":true}');
      expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(sent.headers['x-api-key'], 'sk-secret');
      expect(sent.headers['anthropic-version'], '2026-10-21');
      expect(sent.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
      final body = jsonDecode(sent.body) as Map<String, Object?>;
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('tool_choice'), isFalse);
      expect(body['fallbacks'], 'default');
      expect((body['output_config'] as Map)['format'], {'type': 'json_schema', 'schema': pingSchema});
    });

    test('Anthropic: Haiku gets no fallback, and a rejected beta is retried without it', () async {
      final haiku = <Map<String, String>>[];
      await AnthropicBackend(
        apiKey: 'k1234',
        model: 'claude-haiku-5-5',
        baseUrl: 'https://x/v1',
        transport: _transport((r) async {
          haiku.add(r.headers);
          return _json({
            'stop_reason': 'end_turn',
            'content': [
              {'type': 'text', 'text': '{}'},
            ],
          });
        }),
      ).complete(_request);
      expect(haiku.single.containsKey('anthropic-beta'), isFalse);

      var calls = 0;
      final out = await AnthropicBackend(
        apiKey: 'k1234',
        model: 'claude-opus-5-5',
        baseUrl: 'https://x/v1',
        transport: _transport((r) async {
          calls++;
          if (r.headers.containsKey('anthropic-beta')) {
            return _json({
              'error': {'type': 'invalid_request_error', 'message': 'Unexpected value(s) for the `anthropic-beta` header.'},
            }, 400);
          }
          return _json({
            'stop_reason': 'end_turn',
            'content': [
              {'type': 'text', 'text': '{"a":1}'},
            ],
          });
        }),
      ).complete(_request);
      expect((out, calls), ('{"a":1}', 2));
    });

    test('OpenAI: strict schema and max_completion_tokens; never temperature', () async {
      late Map<String, Object?> body;
      late http.Request sent;
      await OpenAiBackend(
        apiKey: 'sk-abcd',
        model: 'gpt-6.1-sol',
        baseUrl: 'https://api.openai.com/v1',
        transport: _transport((r) async {
          sent = r;
          body = jsonDecode(r.body) as Map<String, Object?>;
          return _json({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'content': '{}'},
              },
            ],
          });
        }),
      ).complete(AiRequest(system: 's', prompt: 'p', schema: pingSchema, images: [AiImage(Uint8List.fromList([255]), 'image/jpeg')]));
      expect(sent.headers['authorization'], 'Bearer sk-abcd');
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body['max_completion_tokens'], 16000);
      expect(((body['response_format'] as Map)['json_schema'] as Map)['strict'], true);
      expect(jsonEncode(body['messages']), contains('data:image/jpeg;base64,/w=='));
    });

    test('Local: no auth header, and falls back when json_schema is unknown', () async {
      final bodies = <Map<String, Object?>>[];
      final out = await OpenAiBackend(
        apiKey: '',
        model: 'llava',
        baseUrl: 'http://localhost:11434/v1',
        local: true,
        transport: _transport((r) async {
          expect(r.headers.containsKey('authorization'), isFalse);
          final b = jsonDecode(r.body) as Map<String, Object?>;
          bodies.add(b);
          if (b.containsKey('response_format')) return _json({'error': 'response_format not supported'}, 400);
          return _json({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'content': '{"ok":true}'},
              },
            ],
          });
        }),
      ).complete(_request);
      expect(out, '{"ok":true}');
      expect(bodies, hasLength(2));
      expect(jsonEncode(bodies.last['messages']), contains('JSON Schema'));
      expect(bodies.first['max_tokens'], 16000);
    });

    test('Gemini: key in header not URL, schema rewritten', () async {
      late http.Request sent;
      await GeminiBackend(
        apiKey: 'AIza-secret',
        model: 'gemini-3.8-flash',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        transport: _transport((r) async {
          sent = r;
          return _json(geminiOk);
        }),
      ).complete(_request);
      expect(sent.url.toString(), 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent');
      expect(sent.url.toString(), isNot(contains('AIza')));
      expect(sent.headers['x-goog-api-key'], 'AIza-secret');
      expect(((jsonDecode(sent.body) as Map)['generationConfig'] as Map)['responseMimeType'], 'application/json');
    });

    test('Gemini schema has no type arrays or additionalProperties anywhere', () {
      final text = jsonEncode(GeminiBackend.toGeminiSchema(extractionSchema));
      expect(text, isNot(contains('additionalProperties')));
      expect(text, isNot(contains('"type":[')));
      expect(text, contains('"nullable":true'));
      expect(jsonDecode(text)['properties']['lab_results']['items']['properties']['legible']['type'], 'boolean');
    });
  });

  group('retries', () {
    test('retries busy and network failures with backoff, then succeeds', () async {
      final slept = <Duration>[];
      var calls = 0;
      final t = _transport((r) async {
        calls++;
        if (calls == 1) return http.Response('overloaded', 529);
        if (calls == 2) throw http.ClientException('connection reset');
        return _json({'ok': true});
      }, slept: slept);
      expect(await t.postJson(Uri.parse('https://x/y'), {}, {}), {'ok': true});
      expect(calls, 3);
      expect(slept, hasLength(2));
      expect(slept[1], greaterThan(slept[0]));
    });

    test('gives up after the last attempt with a friendly error', () async {
      var calls = 0;
      final e = await _failure(_transport((r) async {
        calls++;
        return http.Response('down', 503);
      }).postJson(Uri.parse('https://x/y'), {}, {}));
      expect((calls, e.kind), (3, AiErrorKind.overloaded));
    });

    test('honours Retry-After, but hands long waits to the user', () async {
      final slept = <Duration>[];
      var calls = 0;
      await _transport((r) async {
        calls++;
        return calls == 1 ? _json({}, 429, {'retry-after': '7'}) : _json({'ok': 1});
      }, slept: slept).postJson(Uri.parse('https://x/y'), {}, {});
      expect(slept.single, const Duration(seconds: 7));

      calls = 0;
      final e = await _failure(_transport((r) async {
        calls++;
        return _json({}, 429, {'retry-after': '3600'});
      }).postJson(Uri.parse('https://x/y'), {}, {}));
      expect((calls, e.kind), (1, AiErrorKind.rateLimited));
      expect(e.message, contains('60 minutes'));
    });

    test('never retries what retrying cannot fix', () async {
      for (final (status, body, kind) in [
        (401, {'error': {'message': 'bad'}}, AiErrorKind.auth),
        (402, {'error': {'type': 'billing_error', 'message': 'x'}}, AiErrorKind.quota),
        (429, {'error': {'code': 'insufficient_quota', 'message': 'x'}}, AiErrorKind.quota),
        (404, {'error': {'message': 'no such model'}}, AiErrorKind.modelNotFound),
        (413, {'error': {'message': 'big'}}, AiErrorKind.tooLarge),
        (400, {'error': {'message': 'maximum context length exceeded'}}, AiErrorKind.tooLarge),
        (400, {'error': {'status': 'INVALID_ARGUMENT', 'message': 'API key not valid.'}}, AiErrorKind.auth),
        (400, {'error': {'message': 'nope'}}, AiErrorKind.badRequest),
      ]) {
        var calls = 0;
        final e = await _failure(_transport((r) async {
          calls++;
          return _json(body, status);
        }).postJson(Uri.parse('https://x/y'), {}, {}));
        expect((calls, e.kind), (1, kind), reason: '$status $body');
      }
    });

    test('a timeout stops immediately', () async {
      final t = AiTransport(clientFactory: () => MockClient((r) => Completer<http.Response>().future), timeout: const Duration(milliseconds: 20));
      expect((await _failure(t.postJson(Uri.parse('https://x/y'), {}, {}))).kind, AiErrorKind.timeout);
    });

    test('cancel stops a call that is waiting to retry', () async {
      final cancel = AiCancelToken();
      var calls = 0;
      final t = AiTransport(
        clientFactory: () => MockClient((r) async {
          calls++;
          return http.Response('busy', 503);
        }),
        sleep: (_) => Completer<void>().future,
      );
      final pending = _failure(t.postJson(Uri.parse('https://x/y'), {}, {}, cancel: cancel));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancel.cancel();
      expect((await pending).kind, AiErrorKind.cancelled);
      expect(calls, 1);
    });

    test('keys never reach error text', () {
      final e = AiTransport.classify(401, '{"error":{"message":"Incorrect API key sk-secret-1234 provided"}}', null, {'sk-secret-1234'});
      expect(e.detail, isNot(contains('sk-secret')));
    });

    test('a 200 that is not JSON is an error, not a crash', () async {
      final e = await _failure(_transport((r) async => http.Response('<html>proxy</html>', 200)).postJson(Uri.parse('https://x/y'), {}, {}));
      expect(e.kind, AiErrorKind.invalidResponse);
    });
  });

  group('unusable replies', () {
    AnthropicBackend anthropic(Map<String, Object?> reply) =>
        AnthropicBackend(apiKey: 'k1234', model: 'claude-opus-5-5', baseUrl: 'https://x/v1', transport: _transport((r) async => _json(reply)));
    OpenAiBackend openai(Map<String, Object?> reply) =>
        OpenAiBackend(apiKey: 'k1234', model: 'm', baseUrl: 'https://x/v1', transport: _transport((r) async => _json(reply)));
    GeminiBackend gemini(Map<String, Object?> reply) =>
        GeminiBackend(apiKey: 'k1234', model: 'm', baseUrl: 'https://x/v1', transport: _transport((r) async => _json(reply)));

    test('refusals and cut-off answers are reported, never parsed', () async {
      for (final (call, kind) in [
        (anthropic({'stop_reason': 'refusal', 'content': []}), AiErrorKind.refused),
        (anthropic({'stop_reason': 'max_tokens', 'content': [{'type': 'text', 'text': '{"a":'}]}), AiErrorKind.truncated),
        (anthropic({'stop_reason': 'end_turn', 'content': []}), AiErrorKind.invalidResponse),
        (openai({'choices': [{'finish_reason': 'stop', 'message': {'refusal': 'no', 'content': null}}]}), AiErrorKind.refused),
        (openai({'choices': [{'finish_reason': 'length', 'message': {'content': '{'}}]}), AiErrorKind.truncated),
        (openai({'choices': []}), AiErrorKind.invalidResponse),
        (gemini({'promptFeedback': {'blockReason': 'SAFETY'}}), AiErrorKind.refused),
        (gemini({'candidates': [{'finishReason': 'SAFETY'}]}), AiErrorKind.refused),
        (gemini({'candidates': [{'finishReason': 'MAX_TOKENS', 'content': {'parts': [{'text': '{'}]}}]}), AiErrorKind.truncated),
        (gemini({'candidates': []}), AiErrorKind.invalidResponse),
      ]) {
        expect((await _failure(call.complete(_request))).kind, kind);
      }
    });
  });

  group('settings', () {
    test('off by default, and nothing can run without what it needs', () async {
      final store = MemoryKeyStore();
      await AiSettings.init(store);
      final s = AiSettings.instance;
      expect(s.provider, AiProvider.off);
      expect(s.enabled, isFalse);
      s.provider = AiProvider.gemini;
      expect(s.enabled, isFalse);
      s.perProvider[AiProvider.gemini]!.apiKey = 'AIza123';
      expect(s.enabled, isTrue);
      expect(s.modelFor(AiProvider.gemini), 'gemini-3.8-flash');
      s.consented.add(AiProvider.gemini);
      await s.save();

      await AiSettings.init(store);
      expect(AiSettings.instance.provider, AiProvider.gemini);
      expect(AiSettings.instance.consented, {AiProvider.gemini});
      expect(AiSettings.instance.current.apiKey, 'AIza123');
    });

    test('plain http is only allowed on the private network', () async {
      await AiSettings.init(MemoryKeyStore());
      final s = AiSettings.instance;
      s.provider = AiProvider.local;
      s.perProvider[AiProvider.local]!.model = 'llava';
      for (final (url, ok) in [
        ('', true),
        ('http://192.168.1.20:11434/v1', true),
        ('http://10.0.0.5:1234/v1', true),
        ('http://macbook.local:1234/v1', true),
        ('https://my.server.example/v1', true),
        ('http://my.server.example/v1', false),
        ('http://8.8.8.8/v1', false),
        ('http://172.32.0.1/v1', false),
        ('not a url', false),
      ]) {
        s.perProvider[AiProvider.local]!.baseUrl = url;
        expect(s.enabled, ok, reason: url);
      }
    });
  });
}
