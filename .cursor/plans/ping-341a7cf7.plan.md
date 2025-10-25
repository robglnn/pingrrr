<!-- 341a7cf7-18d6-454a-8541-5bf45476a2e5 2569b7d4-976c-4b01-a242-dfc5b4e70f08 -->
# Pingrrr AI Feature Set: PRD and Implementation Plan

## Goals
- Implement 5 core AI features: real-time translation, language detection, cultural hints, formality adjustment, slang/idiom explanations.
- Deliver advanced agent capabilities: multi-step workflows, proactive suggestions, smart replies, structured summaries.
- Meet SLAs: <1.5s simple ops, <8s complex ops, <15s agent workflows.
- Hybrid UX: Dedicated AI Assistant (pinned chat) + contextual actions in all chats.
- Reliability: 20 requests/day free tier rate limit; caching + RAG; clear loading/error states.

## Scope
- iOS (SwiftUI) frontend, Firebase (Functions + Firestore + Storage) backend, Vercel AI SDK with OpenAI GPT-4.
- US users; last 10 messages context (configurable to full history).

## Non-Goals
- On-device LLM inference.
- Custom model training; only prompt/tool/RAG.

---

## Architecture
- Backend
  - Firebase Functions: `aiProcess`, `aiTranslate`, `aiDetectLang`, `aiExplainSlang`, `aiCulturalHint`, `aiAdjustTone`, `aiSmartReplies`, `aiSummarize`, `aiRateLimitCheck`.
  - Vercel AI SDK agents with tools: translate(), detectLanguage(), getCulturalHint(), adjustFormality(), explainSlang(), summarize(), generateReplies().
  - RAG: fetch last 10 messages (option for full history) from Firestore/SwiftData.
  - Rate limiting per user/day; usage logging (`/usage/{uid}/{yyyy-mm-dd}`) + tier config (`/users/{uid}.tier`).
  - Caching: `/translationCache/{hash}` (source, target, textHash → result, expiresAt).
- Frontend
  - `AIService.swift` (network + state), `AIManager.swift` (or extend `ChatViewModel`) for orchestration.
  - Dedicated AI chat: `AIChatView.swift` + `AIChatViewModel.swift`.
  - Contextual controls: long-press menus; always-visible subtle globe button; smart replies row.
  - Loading/error states; streaming rendering for longer outputs.

---

## Data Model
- Firestore
  - `users/{uid}`: preferences {primaryLang, targetLangs[], defaultFormality, aiTier, dailyUsageCount, lastUsageDate}
  - `usage/{uid}/{yyyy-mm-dd}`: {count}
  - `aiHistory/{uid}/{sessionId}/events` (30 days TTL via Firestore TTL): {type, input, output, latency, tool, tokens}
  - `translationCache/{hash}`: {srcLang, tgtLang, textHash, output, expiresAt}
- SwiftData (local)
  - `AIInteractionEntity` (30-day rolling cache), `UserPreferenceEntity`.

---

## API Contracts (Functions)
- POST callable `aiTranslate`: {text, targetLang?, formality?} → {translatedText, detectedLang, latency}
- POST callable `aiDetectLang`: {text} → {lang, confidence}
- POST callable `aiCulturalHint`: {text, lang, country?} → {hint}
- POST callable `aiAdjustTone`: {text, lang, formality} → {adjusted}
- POST callable `aiExplainSlang`: {text, lang} → {explanation}
- POST callable `aiSmartReplies`: {conversationId, lastN=10} → {replies[3+]}
- POST callable `aiSummarize`: {conversationId, lastN=50} → {summary}
- All endpoints enforce `aiRateLimitCheck(uid)` and write usage + history.

---

## UX Flows
- Dedicated AI Assistant
  - Pinned chat at top (`ConversationsView`): tap → `AIChatView` with quick actions (Translate last message, Summarize thread, Adjust tone).
  - Streaming responses with token-level updates; retry + copy actions.
- Contextual Features (in `ChatView`)
  - Always-visible globe button: tap → detect+translate current or last message inline; show original+translated; toggle.
  - Long-press bubble → menu: Translate, Explain slang, Cultural hint, Adjust tone.
  - Smart replies row above input: 3+ suggestions; tap to insert; thumbs up/down feedback.
- Proactive Assistant
  - Triggers when: language switch detected, idioms/slang detected, user hesitates >5s while typing → suggest formality/translation.

---

## Performance Targets & Strategies
- <1.5s simple ops: preemptive detectLang, aggressive prompt minimization, function cold-start mitigation (min instances=1).
- <8s complex ops: streaming, concise prompts, limit context tokens; RAG last 10 messages by default.
- No offline translation or local cache: all AI requires network. Focus on server-side caching only for repeat requests (optional, later).

---

## Security & Privacy
- US-first rollout; clear AI opt-in; data retained 30 days (TTL index).
- PII minimization in prompts; redact emails/phones by regex before sending.
- User-controlled preferences; easy delete of AI history.

---

## Milestones & Tasks

### M1: Foundation (2–3 days)
- backend-setup
  - Init Functions env: OpenAI key, Vercel AI SDK; add `aiRateLimitCheck`.
  - Create shared util: prompt builder, RAG fetch, caching helpers, usage logging.
- frontend-setup
  - `AIService.swift` with callable wrapper + streaming support.
  - Add `UserPreferences` (formality, langs) in Firestore + local mirror.

### M2: Core Features (3–4 days)
- translate-inline
  - `aiTranslate`, `aiDetectLang`; inline render in bubbles with toggle; auto-translate on mismatch.
- cultural-hints
  - Long-press → `aiCulturalHint`; popover card with concise tips; save to history.
- tone-adjust
  - Long-press → `aiAdjustTone`; settings default; preview before replace.
- slang-explain
  - Long-press → `aiExplainSlang`; tooltip-style explainer with examples.

### M3: Assistant + Smart Replies (3–4 days)
- ai-chat
  - `AIChatView` pinned; quick actions; RAG context selector (last 10/full).
- smart-replies
  - `aiSmartReplies` using RAG + style learning (user past messages); 3+ chips above input; feedback ❯ refine.
- proactive-triggers
  - Typing monitor + language switch detector; suggest translate/tone.

### M4: Reliability, Limits, Polish (2–3 days)
- rate-limits
  - Enforce 20 req/day/user; UX for limit reached; add tier config (free/premium/unlimited placeholders).
- caching-ttl
  - Translation cache with 6–24h TTL; eviction strategy; local device cache.
- loading-error
  - Uniform loading spinners, toast errors, retries, offline queue.
- metrics
  - Log latency, token counts, hit rates; simple dashboard in Firestore.

---

## Files to Add/Change (essentials)
- functions/src/
  - ai/common.ts (prompt utils, cache, RAG fetch, rate limit)
  - ai/translate.ts, detectLang.ts, culturalHint.ts, adjustTone.ts, explainSlang.ts
  - ai/smartReplies.ts, summarize.ts, index.ts exports
- pingrrr/Services/
  - AIService.swift, AIManager.swift (or extend ChatViewModel), AIPreferencesService.swift
- pingrrr/Views/
  - AIChatView.swift, SmartRepliesRow.swift, AIActionsMenu.swift, AILoadingToast.swift
- pingrrr/ViewModels/
  - AIChatViewModel.swift, integrate with ChatViewModel (contextual button + long-press)
- firestore.rules
  - Add rules for usage, aiHistory, translationCache; set TTL policies.

---

## Acceptance Criteria
- All 5 required AI features function with 96%+ success in manual tests across EN/ES/FR/DE/JP basics.
- Simple translate/detect <1.5s median; smart replies <8s; agent workflows <15s.
- AI Assistant pinned and fully interactive with RAG.
- Contextual globe button available in all chats; long-press menu actions work.
- Rate limiting at 20/day enforced; clear UX on limit reached.
- Clean loading and error states; retries and offline queuing implemented.
- AI interaction history retained for 30 days; easy delete.

---

## Risks & Mitigations
- Cold starts: use min instances + warmers.
- Cost spikes: strong rate limiting, caching, batching.
- Latency spikes: stream responses; fallback prompts; cache hits.
- Privacy: prompt redaction; user controls for AI history and preferences.

---

## Open Decisions (tracked but not blocking)
- Iconography for contextual button (globe vs sparkle), finalize during UI pass.
- Paid tiers integration (Stripe); placeholders in backend.
- Full-context toggle UI location (AI chat header vs per-request).


### To-dos

- [ ] Set up Firebase Functions with Vercel AI SDK, env, shared utils (RAG, cache, rate limit)
- [ ] Create AIService.swift and preferences sync; add globe button in ChatView
- [ ] Implement aiTranslate + aiDetectLang; inline toggle UI and auto-translate on mismatch
- [ ] Add cultural hints action via long-press; popover UI and history logging
- [ ] Add formality adjustment action with preview and settings
- [ ] Implement slang/idiom explanation action and tooltip UI
- [ ] Build AIChatView pinned at top; multi-step queries with RAG selector
- [ ] Generate 3+ smart replies with style learning; feedback loop
- [ ] Typing/language detectors to show suggestions when relevant
- [ ] Enforce 20 requests/day/user; limit reached UX; premium tier placeholders
- [ ] Translation cache 6–24h with eviction; local device cache
- [ ] Unified loading/error states; retries; offline queue
- [ ] Latency and token logging; simple dashboard