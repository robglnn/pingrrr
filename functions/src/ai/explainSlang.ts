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

const explainSlangSchema = z.object({
  text: z.string().min(1, 'Text is required'),
  language: z.string().optional(),
});

export const aiExplainSlang = functions
  .region('us-central1')
  .https.onCall(async (data, context) => {
    ensureOpenAIKey();

    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = explainSlangSchema.safeParse(data);
    if (!parsed.success) {
      throw new functions.https.HttpsError('invalid-argument', parsed.error.message);
    }

    await assertUsageAllowance(context.auth.uid);

    const sessionId = buildSessionId();
    const startedAt = Date.now();

    const prompt = buildSlangPrompt({
      text: redactSensitiveData(parsed.data.text),
      language: parsed.data.language,
    });

    try {
      const result = await streamText({
        model: openAIClient.chat(DEFAULT_MODEL),
        messages: [
          {
            role: 'system',
            content: 'Explain slang and idioms clearly with examples. Keep it concise and helpful.',
          },
          { role: 'user', content: prompt },
        ],
      });

      const explanation = (await result.text).trim();

      await recordAIHistory({
        uid: context.auth.uid,
        sessionId,
        type: 'slang-explanation',
        input: parsed.data,
        output: { explanation },
        latencyMs: Date.now() - startedAt,
        tool: 'explain-slang',
      });

      return {
        explanation,
        latencyMs: Date.now() - startedAt,
      };
    } catch (error) {
      functions.logger.error('[aiExplainSlang] Error', error);
      throw new functions.https.HttpsError('internal', 'Failed to explain slang');
    }
  });

function buildSlangPrompt(params: { text: string; language?: string }): string {
  const pieces = [
    'Explain the slang or idiom in the text below in simple terms.',
    'Include what it literally means and how it is typically used.',
  ];

  if (params.language) {
    pieces.push(`The text is in ${params.language}.`);
  }

  pieces.push('Text:');
  pieces.push(params.text);

  return pieces.join('\n');
}

