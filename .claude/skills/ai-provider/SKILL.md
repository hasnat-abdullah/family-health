---
name: ai-provider
description: Add an AI reading provider, or update the suggested models and API details of an existing one. Use when a model is retired, a better one arrives, or a new provider is wanted.
argument-hint: <provider or model>
---

# Change AI providers or models

Check model names and request formats against the provider's current documentation. Don't rely on memory, as they change often, and a wrong default breaks reading for everyone who hasn't chosen a model.

Use only made-up values and synthetic documents. Never send real records to test, and don't call a live API without the user's key and say-so.

## Update models

1. Change the list on the provider in `AiProvider` in `lib/services/ai/ai_config.dart`. The first is the default, so put the recommended one first.
2. Update the table in `README.md` under "AI reading".
3. Check that the model still supports what the backend sends: structured output, images and PDF input. If its parameters differ, change the backend and `test/ai_client_test.dart`.

## Add a provider

1. Add it to `AiProvider`, with its base URL, models and key page. Use https. `isCloud` makes a new provider ask for agreement before its first document, and it must stay that way.
2. If it speaks the OpenAI format, reuse `OpenAiBackend` as `AiProvider.local` does. If not, add a class implementing `AiBackend` in `lib/services/ai/ai_client.dart`, which stays the only file that uses the network.
3. Add it to the switch in `AiBackend.from`. Use `AiTransport`, so retries, backoff, errors and cancelling work the same.
4. Read the provider's data-use and retention terms, and tell the user what you find. Say so in `README.md`, since `SECURITY.md` points people to them.
5. Add tests to `test/ai_client_test.dart`, using `MockClient`: request shape, the key in a header and not the URL, the key stripped from errors, retries, and malformed replies.
6. Run `privacy-reviewer`, then `tool/check.sh`.
