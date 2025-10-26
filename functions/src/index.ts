import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions';
import { z } from 'zod';

import {
  aiAdjustTone,
  aiAssistant,
  aiCulturalHint,
  aiDetectLang,
  aiExplainSlang,
  aiSmartReplies,
  aiSummarize,
  aiTranslate,
} from './ai';

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

const MAX_PARTICIPANTS = 5;

const createConversationSchema = z.object({
  participantEmails: z.array(z.string().email()).min(1).max(MAX_PARTICIPANTS - 1),
  title: z.string().max(120).optional(),
});

export const createConversation = functions
  .region('us-central1')
  .https.onCall(async (data, context) => {
    const { auth } = context;
    if (!auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const parsed = createConversationSchema.safeParse(data);
    if (!parsed.success) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        parsed.error.issues.map((issue) => issue.message).join(', ')
      );
    }

    const requesterUID = auth.uid;
    const { participantEmails, title } = parsed.data;

    try {
      const participants = new Set<string>();
      participants.add(requesterUID);

      for (const emailRaw of participantEmails) {
        const email = emailRaw.trim().toLowerCase();

        let userRecord: admin.auth.UserRecord;
        try {
          userRecord = await admin.auth().getUserByEmail(email);
          console.log('[createConversation] Resolved email', email, 'to UID', userRecord.uid);
        } catch (error: unknown) {
          if ((error as { code?: string }).code === 'auth/user-not-found') {
            throw new functions.https.HttpsError('not-found', `User with email ${email} is not registered.`);
          }

          console.error('[createConversation] getUserByEmail failed for', email, error);
          throw error;
        }

        const userUID = userRecord.uid;
        if (userUID === requesterUID) {
          continue;
        }
        participants.add(userUID);
      }

      if (participants.size < 2) {
        throw new functions.https.HttpsError('failed-precondition', 'Add at least one other registered participant.');
      }

      if (participants.size > MAX_PARTICIPANTS) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          `Group chats can include up to ${MAX_PARTICIPANTS} participants including you.`
        );
      }

      const participantList = Array.from(participants);
      const type = participantList.length > 2 ? 'group' : 'oneOnOne';

      const conversationRef = db.collection('conversations').doc();
      const now = admin.firestore.FieldValue.serverTimestamp();

      await conversationRef.set({
        participants: participantList,
        type,
        title: title?.trim() ?? null,
        createdAt: now,
        createdBy: requesterUID,
        lastMessageTimestamp: now,
        unreadCounts: participantList.reduce(
          (acc, uid) => ({
            ...acc,
            [uid]: 0,
          }),
          {} as Record<string, number>
        ),
      });

      return {
        conversationId: conversationRef.id,
        participantIds: participantList,
        type,
      };
    } catch (error) {
      if (error instanceof functions.https.HttpsError) {
        throw error;
      }

      console.error('[createConversation]', error);
      throw new functions.https.HttpsError('internal', 'Failed to create conversation.');
    }
  });

const userCreatedSchema = z.object({
  uid: z.string(),
  email: z.string().email().optional(),
  displayName: z.string().optional(),
});

export const onAuthUserCreate = functions
  .region('us-central1')
  .auth.user()
  .onCreate(async (user) => {
    const parsed = userCreatedSchema.parse({
      uid: user.uid,
      email: user.email ?? undefined,
      displayName: user.displayName ?? undefined,
    });

    const { uid, email, displayName } = parsed;

    const data: Record<string, unknown> = {
      uid,
      displayName: displayName ?? '',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (email) {
      data.email = email;
      data.emailLower = email.toLowerCase();
    }

    await db
      .collection('users')
      .doc(uid)
      .set(
        {
          ...data,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          photoVersion: 0,
        },
        { merge: true }
      );

    await db
      .collection('subscriptions')
      .doc(uid)
      .set(
        {
          tier: 'free',
          status: 'active',
          source: 'system-default',
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
  });

export {
  aiTranslate,
  aiDetectLang,
  aiCulturalHint,
  aiAdjustTone,
  aiExplainSlang,
  aiSmartReplies,
  aiSummarize,
  aiAssistant,
};

