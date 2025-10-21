# System Patterns – Pingrrr

## Architecture Overview
- **Client**: SwiftUI app structured with MVVM. Views bind to ViewModels that orchestrate SwiftData persistence, Firebase networking, and AI feature triggers.
- **Persistence**: SwiftData models (`User`, `Conversation`, `Message`) mirror Firestore documents to support offline reads and queued writes. Conflict resolution favors server timestamps with optimistic merges.
- **Realtime Messaging**: Firestore snapshot listeners scoped to per-conversation subcollections, limited to recent messages for low latency. Batched writes and indexed queries maintain sub-200 ms delivery.
- **Presence**: Firestore presence documents + connectivity listeners update `onlineStatus` and `lastSeen`. Updates triggered on lifecycle events and network changes.
- **Notifications**: Firebase Cloud Messaging provides foreground notifications; tokens stored on user docs. Cloud Functions broadcast pushes on new messages (MVP scope: ensure foreground handling).
- **AI Pipeline**: Client invokes Firebase Cloud Functions (Option 2 architecture) which proxy Vercel AI SDK/OpenAI GPT-4 calls. Long-press actions trigger translation, context hints, tone adjustments, and slang explanations. Conversation history fed via lightweight RAG pipeline in Functions.

## UI/UX Conventions
- Dark mode only, black backgrounds, white/gray typography, blue accents for outgoing messages and primary actions.
- Conversations list uses Lazy stacks, avatar placeholders, online dots, and last message previews.
- Chat view employs inverted `ScrollView`/`LazyVStack`, message bubbles with status icons (clock, single/double ticks), inline timestamps, and group sender labels.
- Typing indicators and offline banners follow minimalist text-based styling.

## Performance Patterns
- Preload local SwiftData caches on launch to achieve <2 s startup.
- Debounce typing/presence updates (≈500 ms) to minimize writes.
- Use `Task`/`async` concurrency in ViewModels with structured cancellation tied to view lifecycle.
- Limit Firestore listeners to necessary fields; convert to background local updates when app inactive.
- Cache user profiles/avatars locally; refresh opportunistically.

## Security & Reliability
- All API keys reside server-side in Cloud Functions; client communicates only with Firebase services.
- Auth state monitoring ensures unauthenticated users are routed to login instantly.
- SwiftData persistent history ensures no message loss across force quits.
- Push notification tokens refreshed on each launch and stored securely (Firestore user doc field).

