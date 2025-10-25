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

const smartRepliesSchema = ragRequestSchema.extend({
  replyCount: z.number().min(3).max(5).default(3),
});

export const aiSmartReplies = functions
  .region('us-central1')
  .https.onCall(async (data, context) => {
    ensureOpenAIKey();

    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = smartRepliesSchema.safeParse({ ...data, uid: context.auth.uid });
    if (!parsed.success) {
      throw new functions.https.HttpsError('invalid-argument', parsed.error.message);
    }

    await assertUsageAllowance(context.auth.uid);

    const sessionId = buildSessionId();
    const startedAt = Date.now();

    const request = parsed.data;
    const history = await buildConversationContext(request);
    const prompt = buildSmartReplyPrompt({
      history,
      replyCount: request.replyCount,
    });

    try {
      const result = await streamText({
        model: openAIClient.chat(DEFAULT_MODEL),
        messages: [
          {
            role: 'system',
            content:
              "You generate authentic chat replies that match the user's tone and language. Respond in JSON array form.",
          },
          { role: 'user', content: prompt },
        ],
      });

      const replies = parseSmartReplies(await result.text, request.replyCount);

      await recordAIHistory({
        uid: context.auth.uid,
        sessionId,
        type: 'smart-replies',
        input: request,
        output: { replies },
        latencyMs: Date.now() - startedAt,
        tool: 'smart-replies',
      });

      return {
        replies,
        latencyMs: Date.now() - startedAt,
      };
    } catch (error) {
      functions.logger.error('[aiSmartReplies] Error', error);
      throw new functions.https.HttpsError('internal', 'Failed to generate smart replies');
    }
  });

function buildSmartReplyPrompt(params: { history: string; replyCount: number }): string {
  const sanitizedHistory = redactSensitiveData(params.history);

  return [
    'Conversation history:',
    sanitizedHistory,
    '',
    `Generate ${params.replyCount} succinct replies that feel natural for the speaker.`,
    'Return JSON array: ["reply1", "reply2", ...] with no commentary.',
  ].join('\n');
}

function parseSmartReplies(response: string, desiredCount: number): string[] {
  try {
    const start = response.indexOf('[');
    const end = response.lastIndexOf(']');
    if (start === -1 || end === -1) {
      throw new Error('Array not found');
    }
    const json = response.slice(start, end + 1);
    const parsed = JSON.parse(json);
    if (Array.isArray(parsed)) {
      return parsed
        .map((entry) => String(entry).trim())
        .filter((entry) => entry.length > 0)
        .slice(0, desiredCount);
    }
  } catch (error) {
    functions.logger.warn('[aiSmartReplies] Failed to parse response', error, response);
  }

  return [];
}
