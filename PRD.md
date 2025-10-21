# Product Requirements Document (PRD) - Pingrrr

## Overview
This PRD outlines the requirements for building an iOS messaging app using Swift and SwiftUI, integrated with a Firebase backend, auth, functions, Cloud Messaging, and Firestore. The MVP is due by tonight (October 21, 2025, 11:59 PM EDT), targeting the International Communicator persona. The app will provide a production-quality messaging infrastructure with real-time sync, offline support, and AI-enhanced features for seamless cross-language communication. Reliability and speed are the utmost priorities: ensure fastest load times, message delivery, lowest latency, and quick push notifications without any stability loss. The code must establish a firm foundation for scalability and performance.

## Goals
- Deliver a reliable one-on-one and group chat experience with real-time messaging (<200ms delivery on good networks).
- Ensure message persistence and offline functionality with zero data loss.
- Integrate AI features tailored to the International Communicator's needs, enhancing communication across languages.
- Achieve MVP readiness within 24 hours, meeting all specified requirements.
- Prioritize performance: Sub-2s app launch, instant UI updates, smooth 60 FPS interactions, and battery-efficient operations.

## User Persona
- **International Communicator**: People with friends, family, or colleagues speaking different languages.
- **Core Pain Points**: Language barriers, translation nuances, copy-paste overhead, learning difficulty.
- **Target Features**: Address these pain points with AI-driven solutions for effective multilingual communication.

## UI Guidelines
- Take inspiration from Signal and X (Twitter) DM interfaces: Default to dark mode with black backgrounds, white/gray text, and subtle blue accents (e.g., for send buttons or highlights).
- Minimalist, clean, sharp but not too sharp: Use rounded message bubbles with minimal shadows, simple sans-serif fonts (system font like SF Pro), no excessive animations or decorations.
- Signal inspiration: Blue outgoing bubbles on black, input bar with camera/GIF/file icons, clean chat list with avatars and previews.
- X DM inspiration: Gray bubbles, simple "Start a message" input field, bottom toolbar with search and notifications.
- Ensure 60 FPS performance; optimize views to avoid recomputes.
- Dark mode only for MVP; no light mode toggle.

## MVP Requirements (Due Tonight)
### Core Messaging Infrastructure
- **One-on-one chat functionality** with real-time message delivery between 2+ users.
- **Message persistence** to survive app restarts using SwiftData.
- **Optimistic UI updates** where messages appear instantly before server confirmation.
- **Online/offline status indicators** with timestamps.
- **User authentication** via Firebase Auth with user accounts/profiles.
- **Basic group chat functionality** supporting 3+ users.
- **Message read receipts**.
- **Push notifications** working at least in the foreground using Firebase Cloud Messaging.
- **Deployment** on a local emulator/simulator with a deployed Firebase backend.

### Platform
- **iOS Native**: Swift with SwiftUI.

### Testing Scenarios
1. Two devices chatting in real-time.
2. One device going offline, receiving messages, then coming back online.
3. Messages sent while the app is backgrounded.
4. App force-quit and reopened to verify persistence.
5. Poor network conditions (airplane mode, throttled connection).
6. Rapid-fire messages (20+ messages sent quickly).
7. Group chat with 3+ participants.

## AI Features (International Communicator)
### Required Features (All 5)
1. **Real-time translation (inline)**: Accurately and naturally translates messages as they are sent/received.
2. **Language detection & auto-translate**: Automatically detects language and translates without user input.
3. **Cultural context hints**: Provides helpful cultural context for better understanding.
4. **Formality level adjustment**: Adjusts tone to match appropriate formality.
5. **Slang/idiom explanations**: Clarifies slang and idioms for clearer communication.

### Advanced Feature (Choose 1)
- **A) Context-Aware Smart Replies**: Learns your style in multiple languages and suggests authentic replies.
- **B) Intelligent Processing**: Extracts structured data from multilingual conversations.

### AI Integration
- **Architecture**: Use Option 2 (Contextual AI Features) with long-press message actions for translate/summarize/extract.
- **Framework**: Vercel AI SDK for streamlined agent development.
- **Implementation**: Leverage OpenAI GPT-4 via Firebase Cloud Functions, with RAG pipelines for conversation history.

## Technical Architecture
### Backend
- **Firebase Firestore**: Real-time database for message sync; use indexed queries and batched operations for low latency.
- **Firebase Cloud Functions**: Serverless backend for AI calls, securing API keys.
- **Firebase Auth**: User authentication.
- **Firebase Cloud Messaging (FCM)**: Push notifications; optimize for quick delivery with silent pushes.

### Mobile (iOS)
- **Swift with SwiftUI**: For UI development; use LazyVStack and efficient modifiers for performance.
- **SwiftData**: Local storage for offline persistence; ensure fast querying.
- **URLSession**: Networking with Firebase SDK; cache responses where possible.
- **Deployment**: Via TestFlight.

### AI Integration
- **OpenAI GPT-4**: Called from Cloud Functions; cache common responses to reduce latency.
- **Vercel AI SDK**: For agent functionality.
- **RAG Pipeline**: Conversation history retrieval; limit scope for speed.

### Concerns and Pitfalls
- **Real-Time Sync**: Ensure Firestore listeners handle high message volumes without lag. Use batch writes to manage rapid-fire messaging and aim for sub-200ms delivery.
- **Offline Support**: Implement robust queueing with SwiftData to handle network drops; test reconnection sync time (<1 second) with zero message loss.
- **AI Latency**: Optimize Cloud Function calls to GPT-4 to meet <2s response time; cache frequent translations.
- **Battery Efficiency**: Minimize background WebSocket activity with FCM push triggers; no excessive polling.
- **Security**: Store API keys only in Cloud Functions, never in the client app.
- **Performance**: Optimize SwiftUI for 60 FPS scrolling with 1000+ messages; handle keyboard transitions smoothly; preload data for <2s launch.
- **Edge Cases**: Test mixed languages, empty chats, and poor network conditions to ensure AI accuracy and overall stability.

## Deliverables
- **GitHub Repository**: With README, setup instructions, and code.
- **Demo Video**: 5-7 minutes showing real-time messaging, group chat, offline scenario, app lifecycle, and all 5 AI features.
- **TestFlight Link**: For iOS deployment.
- **Persona Brainlift**: 1-page document justifying the International Communicator persona and feature alignment.
- **Social Post**: On X with demo video, tagging @GauntletAI.

## Success Criteria
- MVP passes all checkpoint requirements with reliable message delivery.
- AI features achieve 90%+ accuracy and <2s response time.
- App launches in <2 seconds and handles lifecycle transitions seamlessly.
- Achieve excellent rubric scores: Sub-200ms message delivery, sub-1s sync on reconnect, smooth performance with 1000+ messages.