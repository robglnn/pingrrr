import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions';
import { createOpenAI } from '@ai-sdk/openai';
import { z } from 'zod';

const DAILY_USAGE_LIMIT_FREE = 300;
const DAILY_USAGE_LIMIT_PRO = 300;
const DEFAULT_TIER = 'free';

interface ConversationMessageData {
  senderID?: string;
  senderId?: string;
  sender?: string;
  senderDisplayName?: string;
  content?: string;
  body?: string;
}

const openAiKey = process.env.OPENAI_API_KEY || functions.config()?.openai?.key;

if (!openAiKey) {
  functions.logger.warn('OPENAI_API_KEY is not set. AI features will be disabled.');
}

export const openAIClient = createOpenAI({
  apiKey: openAiKey ?? '',
});

export const DEFAULT_MODEL = 'gpt-4.1-mini';

const usageDocPath = (uid: string, dateKey: string) => `usage/${uid}_${dateKey}`;

const getDateKey = (): string => {
  const now = new Date();
  return now.toISOString().split('T')[0];
};

export async function assertUsageAllowance(uid: string, increment = 1): Promise<void> {
  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing user id for rate limiting.');
  }

  const dateKey = getDateKey();
  const docRef = admin.firestore().doc(usageDocPath(uid, dateKey));
  const snap = await docRef.get();
  const data = snap.data() ?? { count: 0, tier: DEFAULT_TIER };

  const subscriptionDoc = await admin.firestore().collection('subscriptions').doc(uid).get();
  const subscriptionTier = (subscriptionDoc.data()?.tier as string | undefined) ?? DEFAULT_TIER;

  const tierLimit = resolveTierLimit(subscriptionTier);
  const currentCount = data?.count ?? 0;

  if (tierLimit >= 0 && currentCount + increment > tierLimit) {
    throw new functions.https.HttpsError(
      'resource-exhausted',
      'Daily AI request limit reached. Upgrade to a higher tier for more requests.'
    );
  }

  await docRef.set(
    {
      count: admin.firestore.FieldValue.increment(increment),
      tier: subscriptionTier,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

function resolveTierLimit(tier: string): number {
  switch (tier) {
    case 'unlimited':
      return -1;
    case 'pro':
    case 'premium':
      return DAILY_USAGE_LIMIT_PRO;
    case 'free':
    default:
      return DAILY_USAGE_LIMIT_FREE;
  }
}

export async function recordAIHistory(params: {
  uid: string;
  sessionId: string;
  type: string;
  input: unknown;
  output: unknown;
  latencyMs: number;
  tool: string;
  tokens?: number;
}): Promise<void> {
  const { uid, sessionId, ...rest } = params;
  if (!uid || !sessionId) return;

  await admin
    .firestore()
    .collection('aiHistory')
    .doc(uid)
    .collection('sessions')
    .doc(sessionId)
    .collection('events')
    .add({
      ...rest,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
}

export async function fetchConversationHistory(conversationId: string, limit = 10) {
  const snapshot = await admin
    .firestore()
    .collection('conversations')
    .doc(conversationId)
    .collection('messages')
    .orderBy('timestamp', 'desc')
    .limit(limit)
    .get();

  const messages = snapshot.docs
    .map((doc) => {
      const data = doc.data() as ConversationMessageData;
      return {
        id: doc.id,
        ...data,
      };
    })
    .reverse();

  return messages;
}

export const ragRequestSchema = z.object({
  conversationId: z.string(),
  lastN: z.number().min(1).max(200).default(10),
  uid: z.string(),
  includeFullHistory: z.boolean().optional(),
});

export type RAGRequest = z.infer<typeof ragRequestSchema>;

export async function buildConversationContext({
  conversationId,
  lastN,
  includeFullHistory,
}: RAGRequest): Promise<string> {
  const limit = includeFullHistory ? 200 : lastN;
  const messages = await fetchConversationHistory(conversationId, limit);

  const senderIDs = Array.from(
    new Set(
      messages
        .map((entry) => entry.senderID || entry.senderId)
        .filter((value): value is string => !!value)
    )
  );

  const displayNameMap = await fetchDisplayNames(senderIDs);

  return messages
    .map((entry) => {
      const rawSender = entry.senderID || entry.senderId || entry.sender || 'Unknown';
      const prettySender =
        entry.senderDisplayName || displayNameMap.get(rawSender) || rawSender;
      const content = entry.content || entry.body || '';
      return `${prettySender}: ${content}`;
    })
    .join('\n');
}

async function fetchDisplayNames(userIDs: string[]): Promise<Map<string, string>> {
  const results = new Map<string, string>();
  if (userIDs.length === 0) {
    return results;
  }

  const chunkSize = 10;
  for (let index = 0; index < userIDs.length; index += chunkSize) {
    const chunk = userIDs.slice(index, index + chunkSize);
    const snapshot = await admin
      .firestore()
      .collection('users')
      .where(admin.firestore.FieldPath.documentId(), 'in', chunk)
      .get();

    snapshot.docs.forEach((doc) => {
      const displayName = doc.get('displayName') as string | undefined;
      if (displayName) {
        results.set(doc.id, displayName);
      }
    });
  }

  return results;
}

export function redactSensitiveData(text: string): string {
  return text
    .replace(/\b[\w.-]+@[\w.-]+\.[A-Za-z]{2,6}\b/g, '[email]')
    .replace(/\b\+?\d[\d\s.-]{6,}\b/g, '[phone]');
}

export function buildSessionId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

export function ensureOpenAIKey(): void {
  if (!openAiKey) {
    throw new functions.https.HttpsError('failed-precondition', 'OpenAI API key is not configured.');
  }
}

