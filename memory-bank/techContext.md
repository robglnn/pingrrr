# Tech Context – Pingrrr

## Platform & Frameworks
- **iOS 17+**, Swift, SwiftUI, MVVM architecture.
- **SwiftData** for local persistence/offline cache, with lightweight models mirroring Firestore.
- **Firebase SDKs** via Swift Package Manager: Auth, Firestore, Messaging, Functions.
- **Concurrency**: Swift Concurrency (`async/await`) for networking and data sync.

## Firebase Setup
- Firebase project configured with Auth (Email/Password), Firestore, Cloud Messaging, and Cloud Functions.
- `FirebaseApp.configure()` executed in `AppDelegate` (`firebaseinit-code.md`).
- Firestore persistence enabled with tuned cache size for low latency.
- Messaging requires Push Notifications and Background Modes capabilities enabled in Xcode.

## AI Stack
- Vercel AI SDK used within Cloud Functions to orchestrate OpenAI GPT-4 calls.
- RAG pipeline leverages recent conversation history stored in Firestore, fetched securely server-side.
- Client invokes AI features through callable HTTPS Cloud Functions, ensuring API keys remain server-only.

## Tooling & Deployment
- Project managed in Xcode; builds target simulator initially.
- Continuous testing via iOS Simulator scenarios outlined in `MVPtasks.md` (offline, rapid messages, group chat, etc.).
- Future deployment path: TestFlight distribution, GitHub repo documentation, demo video capture.

## Performance Targets
- <2 s cold launch via preloading SwiftData caches and deferring heavy Firestore work.
- Sub-200 ms message delivery by combining optimistic UI, batched writes, and Firestore listeners.
- <1 s reconnect sync using queued SwiftData messages and incremental Firestore fetches.

