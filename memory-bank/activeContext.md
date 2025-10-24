# Active Context – Pingrrr

## Current Focus (Oct 24, 2025)
- Ship MVP-critical messaging refinements (profile editing, smart message display, local chat deletion, read receipts, media/voice pipelines).
- Maintain reliability and low-latency sync while layering new UX polish.
- Keep work aligned with `MVPtasks.md`, `MVPcriticalrequirements.md`, and performance rubric targets.

## Recent Actions
- Delivered profile management: profile photo upload via Firebase Storage, display name editing, rules deployed, callable function wired.
- Implemented WhatsApp-style message grouping in chat view with sender name/avatar logic and profile prefetching.
- Hardened foreground notification pipeline for new messages and verified clean builds post-integration.

## Immediate Next Steps
- Add swipe-to-delete conversations (local only) with confirmation flow.
- Build read receipts UI (overlapping avatars + popover) and ensure data pipeline is ready.
- Implement media sharing pipeline with caching, camera/library pickers, and background fetches.
- Develop voice message capture/playback (30s cap, read on play, auto-delete warning) leveraging `VoiceMessageService` scaffolding.
- Expand testing matrix: new chat creation, grouped message rendering, profile updates, media uploads, offline delivery.

## Key Considerations
- Preserve sub-200 ms delivery by keeping snapshot listeners scoped and caches efficient.
- Ensure dark-mode visual consistency (avatars, bubbles, toasts) across new UI elements.
- Coordinate Firebase rules/functions deployment as new media/voice features come online.
- Monitor SwiftData persistence for grouped view alignment to avoid duplicate rendering or stale reads.

