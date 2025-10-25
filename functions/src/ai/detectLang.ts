import * as functions from 'firebase-functions';
import { z } from 'zod';
import { streamText } from 'ai';

import {
  assertUsageAllowance,
  buildSessionId,
  DEFAULT_MODEL,
  ensureOpenAIKey,
  openAIClient,
  recordAIHistory,
  redactSensitiveData,
} from './common';

const detectLangSchema = z.object({
  text: z.string().min(1, 'Text is required'),
});

export const aiDetectLang = functions
  .region('us-central1')
  .https.onCall(async (data, context) => {
    ensureOpenAIKey();

    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = detectLangSchema.safeParse(data);
    if (!parsed.success) {
      throw new functions.https.HttpsError('invalid-argument', parsed.error.message);
    }

    await assertUsageAllowance(context.auth.uid);

    const sessionId = buildSessionId();
    const startedAt = Date.now();

    const prompt = buildDetectionPrompt(redactSensitiveData(parsed.data.text));

    try {
      const result = await streamText({
        model: openAIClient.chat(DEFAULT_MODEL),
        messages: [
          {
            role: 'system',
            content: 'You are a language detection engine. Respond with JSON only.',
          },
          { role: 'user', content: prompt },
        ],
      });

      const responseText = await result.text;
      const detected = parseDetectionResponse(responseText);

      await recordAIHistory({
        uid: context.auth.uid,
        sessionId,
        type: 'language-detection',
        input: parsed.data,
        output: detected,
        latencyMs: Date.now() - startedAt,
        tool: 'detect-language',
      });

      return {
        ...detected,
        latencyMs: Date.now() - startedAt,
      };
    } catch (error) {
      functions.logger.error('[aiDetectLang] Error', error);
      throw new functions.https.HttpsError('internal', 'Language detection failed');
    }
  });

function buildDetectionPrompt(text: string): string {
  return [
    'Detect the language of the following text.',
    'Respond with JSON in the format { "language": "<BCP-47 code>", "name": "English", "confidence": 0.98 }.',
    'If text is mixed, return the dominant language.',
    'Text:',
    text,
  ].join('\n');
}

function parseDetectionResponse(responseText: string) {
  try {
    const jsonStart = responseText.indexOf('{');
    const jsonEnd = responseText.lastIndexOf('}');
    if (jsonStart === -1 || jsonEnd === -1) {
      throw new Error('JSON not found');
    }
    const jsonString = responseText.slice(jsonStart, jsonEnd + 1);
    const parsed = JSON.parse(jsonString) as {
      language: string;
      name?: string;
      confidence?: number;
    };

    return {
      language: parsed.language ?? 'unknown',
      name: parsed.name ?? parsed.language ?? 'Unknown',
      confidence: parsed.confidence ?? 0,
    };
  } catch (error) {
    functions.logger.warn('[aiDetectLang] Failed to parse response', error, responseText);
    return {
      language: 'unknown',
      name: 'Unknown',
      confidence: 0,
    };
  }
}



