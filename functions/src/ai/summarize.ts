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
} from './common';

const summarizeSchema = ragRequestSchema.extend({
  promptStyle: z.enum(['concise', 'detailed']).default('concise'),
});

export const aiSummarize = functions
  .runWith({ secrets: ['OPENAI_API_KEY'] })
  .region('us-central1')
  .https.onCall(async (data, context) => {
    ensureOpenAIKey();

    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = summarizeSchema.safeParse({ ...data, uid: context.auth.uid });
    if (!parsed.success) {
      throw new functions.https.HttpsError('invalid-argument', parsed.error.message);
    }

    await assertUsageAllowance(context.auth.uid);

    const sessionId = buildSessionId();
    const startedAt = Date.now();

    const request = parsed.data;
    const contextText = await buildConversationContext(request);
    const prompt = buildSummaryPrompt(contextText, request.promptStyle);

    try {
      const result = await streamText({
        model: openAIClient.chat(DEFAULT_MODEL),
        messages: [
          {
            role: 'system',
            content: 'Summarize conversations clearly. Provide actionable highlights and next steps when relevant.',
          },
          { role: 'user', content: prompt },
        ],
      });

      const summary = (await result.text).trim();

      await recordAIHistory({
        uid: context.auth.uid,
        sessionId,
        type: 'summary',
        input: request,
        output: { summary },
        latencyMs: Date.now() - startedAt,
        tool: 'summarize',
      });

      return {
        summary,
        latencyMs: Date.now() - startedAt,
      };
    } catch (error) {
      functions.logger.error('[aiSummarize] Error', error);
      throw new functions.https.HttpsError('internal', 'Failed to generate summary');
    }
  });

function buildSummaryPrompt(context: string, style: 'concise' | 'detailed'): string {
  const intro = style === 'concise'
    ? 'Summarize the following conversation in 3-4 bullet points. Focus on key decisions, requests, and follow-ups.'
    : 'Provide a detailed summary of the following conversation. Include key points, action items, and tone recommendations.';

  return `${intro}\n\nConversation History:\n${context}`;
}
