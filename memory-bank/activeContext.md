# Active Context – Pingrrr

## Current Focus (Oct 21, 2025)
- Drive MVP implementation forward with emphasis on reliability, presence, notifications, AI assistance, and group collaboration.
- Harden offline/online sync paths while polishing realtime experience to hit performance targets.
- Ensure work stays aligned with `MVPtasks.md`, `MVPcriticalrequirements.md`, and rubric KPIs (sub-200 ms delivery, 60 FPS, <2 s launch).

## Recent Actions
- Created Memory Bank to track project brief, product context, system patterns, and technical setup.
- Confirmed Firebase initialization snippet (`firebaseinit-code.md`) provided for AppDelegate configuration.

## Immediate Next Steps
- Finish offline resilience: persist outgoing messages in SwiftData, retry with exponential backoff, and reconcile local/remote state on reconnect.
- Surface presence: render online/offline indicators and last-seen timestamps in `ConversationsView` and `ChatView`.
- Flesh out notifications: implement foreground FCM handling and ensure Cloud Function triggers fire for new messages.
- Integrate required AI features (translation, tone, cultural context, slang explanations) via Cloud Functions + Vercel AI SDK.
- Add group chat creation/management UI with editable metadata (participants, titles).
- Polish/test: rapid-fire messaging, offline scenarios, backgrounding, push reception, performance (<2 s launch, 60 FPS).

## Key Considerations
- Prioritize performance targets: <200 ms message delivery, <2 s launch, 60 FPS interactions.
- Maintain dark-mode aesthetic consistent with Signal/X inspirations.
- Ensure architecture supports upcoming AI features without major refactors.
- Prepare for required test scenarios (offline, background/foreground, rapid-fire messaging, group chat).

