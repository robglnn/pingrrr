# Active Context – Pingrrr

## Current Focus (Oct 21, 2025)
- Begin MVP implementation for Pingrrr iOS app using existing Firebase setup.
- Establish project structure (MVVM, SwiftData models, Firebase integration) and core messaging flows.
- Ensure adherence to `MVPtasks.md` checklist with priority on real-time messaging reliability and offline support.

## Recent Actions
- Created Memory Bank to track project brief, product context, system patterns, and technical setup.
- Confirmed Firebase initialization snippet (`firebaseinit-code.md`) provided for AppDelegate configuration.

## Immediate Next Steps
- Implement SwiftData models (`User`, `Conversation`, `Message`) aligning with Firestore schema.
- Build authentication flow (login/signup, state monitoring) with Firebase Auth.
- Construct conversations list and chat views with real-time Firestore listeners, optimistic UI, and read receipts.
- Integrate presence tracking, typing indicators, and offline queue handling.
- Configure FCM foreground notification handling.

## Key Considerations
- Prioritize performance targets: <200 ms message delivery, <2 s launch, 60 FPS interactions.
- Maintain dark-mode aesthetic consistent with Signal/X inspirations.
- Ensure architecture supports upcoming AI features without major refactors.
- Prepare for required test scenarios (offline, background/foreground, rapid-fire messaging, group chat).

