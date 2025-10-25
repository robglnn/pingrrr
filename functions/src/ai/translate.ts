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

const translateSchema = z.object({
  text: z.string().min(1, 'Text is required'),
  targetLang: z.string().optional(),
  formality: z.enum(['formal', 'informal']).optional(),
});

export const aiTranslate = functions
  .runWith({ secrets: ['OPENAI_API_KEY'] })
  .region('us-central1')
  .https.onCall(async (data, context) => {
    ensureOpenAIKey();

    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = translateSchema.safeParse(data);
    if (!parsed.success) {
      throw new functions.https.HttpsError('invalid-argument', parsed.error.message);
    }

    await assertUsageAllowance(context.auth.uid);

    const sessionId = buildSessionId();
    const startedAt = Date.now();

    const { text, targetLang, formality } = parsed.data;

    const prompt = buildTranslationPrompt({
      text: redactSensitiveData(text),
      targetLang,
      formality,
    });

    try {
      const result = await streamText({
        model: openAIClient.chat(DEFAULT_MODEL),
        messages: [
          {
            role: 'system',
            content: 'You are a professional translator. Provide natural, accurate translations.',
          },
          { role: 'user', content: prompt },
        ],
      });

      const translatedText = await result.text;

      await recordAIHistory({
        uid: context.auth.uid,
        sessionId,
        type: 'translation',
        input: { text, targetLang, formality },
        output: { translatedText },
        latencyMs: Date.now() - startedAt,
        tool: 'translate',
      });

      return {
        translatedText,
        latencyMs: Date.now() - startedAt,
      };
    } catch (error) {
      functions.logger.error('[aiTranslate] Error', error);
      throw new functions.https.HttpsError('internal', 'Translation failed');
    }
  });

function buildTranslationPrompt(params: {
  text: string;
  targetLang?: string;
  formality?: 'formal' | 'informal';
}): string {
  const { text, targetLang, formality } = params;
  const instructions: string[] = [];

  if (targetLang) {
    instructions.push(`Translate the following text into ${targetLang}.`);
  } else {
    instructions.push('Translate the following text into the reader\'s preferred language.');
  }

  if (formality) {
    instructions.push(`Use a ${formality} tone.`);
  } else {
    instructions.push('Use a natural, context-appropriate tone.');
  }

  instructions.push('Respond with only the translated text, no additional commentary.');

  return `${instructions.join(' ')}\n\nText:\n${text}`;
}

