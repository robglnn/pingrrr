# Active Context – Pingrrr

## Current Focus (Oct 26, 2025)
- Stand up the post-MVP AI stack: callable functions backed by Vercel AI SDK + OpenAI, contextual in-chat actions, and upcoming AI assistant experience.
- Maintain messaging reliability (SwiftData + Firestore) while layering AI without regressing latency.
- Keep implementation aligned with `ping.plan.md`, covering translation, cultural guidance, smart replies, and proactive assistance.

## Recent Actions
- Deployed callable AI functions (`aiTranslate`, `aiDetectLang`, `aiCulturalHint`, `aiAdjustTone`, `aiExplainSlang`, `aiSmartReplies`, `aiSummarize`, `aiAssistant`) with Firebase Secrets + OpenAI key.
- Wired `AIService`/`AIPreferencesService` on iOS so long-press actions surface translation, slang explanations, cultural hints, and tone adjustments inline.
- Added contextual insight bubbles in chat UI and ensured Firestore/Vercel secrets stay aligned.
- Built the dedicated AI Assistant chat view with context selection, quick actions, and assistant responses.
- Raised the daily AI allowance to 100 requests for free users and fixed the inline translation action by cleaning callable payloads.
- Implemented version-aware `ProfileImageCache` + `AsyncProfileImageView`, reusing avatars for chat rows, read receipts, and settings without redundant downloads.
- Resolved SwiftData migration errors by allowing optional `photoVersion` values and added an explicit `AppMain` entry point, restoring clean Xcode builds.

## Immediate Next Steps
- Polish translation toggle UX (globe button feedback) and capture translation history for assistant chat.
- Implement smart replies surface + thumbs feedback and proactive prompts (language switch, typing pause).
- Add rate-limit UX (100 req/day) and latency/token logging per plan.
- Begin integrating assistant responses with saved history (aiHistory) for future analytics.

## Key Considerations
- Monitor Firestore/Storage footprint; simulator previously hit space limits from cached media + offline DB.
- Plan migration to Node 20 / `firebase-functions` ≥5.1.0 before Oct 30 deprecation.
- Maintain dark-mode visual consistency for new AI UI elements and ensure accessibility (copy buttons, status spinners).

