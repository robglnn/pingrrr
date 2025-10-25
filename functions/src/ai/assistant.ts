import * as functions from 'firebase-functions';
import { z } from 'zod';
import { streamText } from 'ai';

import {
  assertUsageAllowance,
  buildConversationContext,
  buildSessionId,
  DEFAULT_MODEL,
  ensureOpenAIKey,
  openAIClient,
  ragRequestSchema,
  recordAIHistory,
  redactSensitiveData,
} from './common';

const assistantSchema = ragRequestSchema.extend({
  prompt: z.string().min(1, 'Prompt is required'),
});

export const aiAssistant = functions
  .runWith({ secrets: ['OPENAI_API_KEY'] })
  .region('us-central1')
  .https.onCall(async (data, context) => {
    ensureOpenAIKey();

    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = assistantSchema.safeParse({ ...data, uid: context.auth.uid });
    if (!parsed.success) {
      throw new functions.https.HttpsError('invalid-argument', parsed.error.message);
    }

    await assertUsageAllowance(context.auth.uid);

    const sessionId = buildSessionId();
    const startedAt = Date.now();

    const request = parsed.data;
    let contextText = '';
    if (request.conversationId) {
      contextText = await buildConversationContext(request);
    }

    const prompt = buildAssistantPrompt({
      prompt: redactSensitiveData(request.prompt),
      context: contextText,
    });

    try {
      const result = await streamText({
        model: openAIClient.chat(DEFAULT_MODEL),
        messages: [
          {
            role: 'system',
            content:
              'You are Pingrrr\'s multilingual assistant. Use conversation context if provided, otherwise answer generally. Offer translations, tone suggestions, and cultural tips when helpful.',
          },
          { role: 'user', content: prompt },
        ],
      });

      const reply = (await result.text).trim();

      await recordAIHistory({
        uid: context.auth.uid,
        sessionId,
        type: 'assistant-chat',
        input: request,
        output: { reply },
        latencyMs: Date.now() - startedAt,
        tool: 'assistant',
      });

      return {
        reply,
        latencyMs: Date.now() - startedAt,
      };
    } catch (error) {
      functions.logger.error('[aiAssistant] Error', error);
      throw new functions.https.HttpsError('internal', 'Assistant failed to respond');
    }
  });

function buildAssistantPrompt(params: { prompt: string; context: string }): string {
  if (!params.context) {
    return params.prompt;
  }

  return [
    'Conversation Context:\n',
    params.context,
    '\n---\n',
    'User Request:',
    params.prompt,
  ].join('');
}
