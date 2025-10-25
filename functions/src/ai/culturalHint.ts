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

const culturalHintSchema = z.object({
  text: z.string().min(1, 'Text is required'),
  language: z.string().nullish(),
  audienceCountry: z.string().nullish(),
});

export const aiCulturalHint = functions
  .runWith({ secrets: ['OPENAI_API_KEY'] })
  .region('us-central1')
  .https.onCall(async (data, context) => {
    ensureOpenAIKey();

    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = culturalHintSchema.safeParse(data);
    if (!parsed.success) {
      throw new functions.https.HttpsError('invalid-argument', parsed.error.message);
    }

    await assertUsageAllowance(context.auth.uid);

    const sessionId = buildSessionId();
    const startedAt = Date.now();

    const { text, language, audienceCountry } = parsed.data;
    const prompt = buildCulturalPrompt({
      text: redactSensitiveData(text),
      language: language ?? undefined,
      audienceCountry: audienceCountry ?? undefined,
    });

    try {
      const result = await streamText({
        model: openAIClient.chat(DEFAULT_MODEL),
        messages: [
          {
            role: 'system',
            content:
              'You are a cultural liaison. Give brief, practical context to avoid misunderstandings. Respond in the user\'s language when possible.',
          },
          { role: 'user', content: prompt },
        ],
      });

      const hint = (await result.text).trim();

      await recordAIHistory({
        uid: context.auth.uid,
        sessionId,
        type: 'cultural-hint',
        input: parsed.data,
        output: { hint },
        latencyMs: Date.now() - startedAt,
        tool: 'cultural-hint',
      });

      return {
        hint,
        latencyMs: Date.now() - startedAt,
      };
    } catch (error) {
      functions.logger.error('[aiCulturalHint] Error', error);
      throw new functions.https.HttpsError('internal', 'Failed to generate cultural hint');
    }
  });

function buildCulturalPrompt(params: {
  text: string;
  language?: string;
  audienceCountry?: string;
}): string {
  const parts = [
    'Provide a concise cultural context to help the sender communicate appropriately.',
    'Focus on etiquette, tone, or references that might be misunderstood.',
  ];

  if (params.language) {
    parts.push(`The message language is ${params.language}.`);
  }

  if (params.audienceCountry) {
    parts.push(`The recipient is located in ${params.audienceCountry}.`);
  }

  parts.push('Message:');
  parts.push(params.text);
  parts.push('Respond with 2-3 sentences.');

  return parts.join('\n');
}


