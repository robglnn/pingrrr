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

const adjustToneSchema = z.object({
  text: z.string().min(1, 'Text is required'),
  language: z.string().optional(),
  formality: z.enum(['formal', 'informal']).default('formal'),
});

export const aiAdjustTone = functions
  .runWith({ secrets: ['OPENAI_API_KEY'] })
  .region('us-central1')
  .https.onCall(async (data, context) => {
    ensureOpenAIKey();

    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = adjustToneSchema.safeParse(data);
    if (!parsed.success) {
      throw new functions.https.HttpsError('invalid-argument', parsed.error.message);
    }

    await assertUsageAllowance(context.auth.uid);

    const sessionId = buildSessionId();
    const startedAt = Date.now();

    const prompt = buildTonePrompt({
      text: redactSensitiveData(parsed.data.text),
      language: parsed.data.language,
      formality: parsed.data.formality,
    });

    try {
      const result = await streamText({
        model: openAIClient.chat(DEFAULT_MODEL),
        messages: [
          {
            role: 'system',
            content: 'You rewrite text to match the requested tone while preserving meaning. Respond only with the adjusted text.',
          },
          { role: 'user', content: prompt },
        ],
      });

      const adjustedText = (await result.text).trim();

      await recordAIHistory({
        uid: context.auth.uid,
        sessionId,
        type: 'formality-adjustment',
        input: parsed.data,
        output: { adjustedText },
        latencyMs: Date.now() - startedAt,
        tool: 'adjust-tone',
      });

      return {
        adjustedText,
        latencyMs: Date.now() - startedAt,
      };
    } catch (error) {
      functions.logger.error('[aiAdjustTone] Error', error);
      throw new functions.https.HttpsError('internal', 'Failed to adjust tone');
    }
  });

function buildTonePrompt(params: {
  text: string;
  language?: string;
  formality: 'formal' | 'informal';
}): string {
  const instructions = [
    `Rewrite the following text to sound ${params.formality}.`,
    'Keep the meaning intact. Maintain natural phrasing for the given language.',
  ];

  if (params.language) {
    instructions.push(`The text is in ${params.language}.`);
  }

  instructions.push('Text:');
  instructions.push(params.text);

  return instructions.join('\n');
}


