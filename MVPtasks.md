# MVP Tasks for Pingrrr iOS App

## Overview
This document outlines the step-by-step tasks to implement the MVP requirements for Pingrrr, an iOS messaging app built with Swift and SwiftUI, using Firebase for backend services. The focus is on delivering a solid core messaging infrastructure with real-time sync, offline support, and basic features. AI features for the International Communicator persona will be handled in a subsequent postMVPtasks.md.

**Key Goals for MVP:**
- Achieve excellent rubric scores in Core Messaging Infrastructure (35 points) and Mobile App Quality (20 points).
- Ensure reliable real-time message delivery (<200ms on good networks), offline persistence, and group chat functionality.
- Prioritize reliability and speed above all: fastest load times, message delivery, lowest latency, and quick push notifications without any stability loss. Code must set a firm foundation for scalability.
- Test against all specified scenarios.
- App must run on iOS simulator/emulator with deployed Firebase backend.

**Tech Stack:**
- Frontend: Swift, SwiftUI
- Local Storage: SwiftData for offline persistence
- Backend: Firebase (Auth, Firestore, Cloud Functions, Cloud Messaging)
- Networking: Firebase SDK, URLSession where needed

**Project Setup Notes:**
- App Name: Pingrrr
- Minimum iOS Version: 17.0
- Use MVVM architecture for clean separation.
- Prioritize vertical slices: Get end-to-end messaging working first before polishing.
- Test on physical devices where possible for accurate lifecycle and network behavior.

**UI Guidelines:**
- Take inspiration from Signal and X (Twitter) DM interfaces: Default to dark mode with black backgrounds, white/gray text, and subtle blue accents (e.g., for send buttons or highlights).
- Minimalist, clean, sharp but not too sharp: Use rounded message bubbles with minimal shadows, simple sans-serif fonts (system font like SF Pro), no excessive animations or decorations.
- Signal inspiration: Blue outgoing bubbles on black, input bar with camera/GIF/file icons, clean chat list with avatars and previews.
- X DM inspiration: Gray bubbles, simple "Start a message" input field, bottom toolbar with search and notifications.
- Ensure 60 FPS performance; optimize views to avoid recomputes.
- Dark mode only for MVP; no light mode toggle.

## Task Breakdown

### 1. Project Setup and Firebase Integration
1.1 Create a new Xcode project named "Pingrrr" using SwiftUI App template. Set up the main App struct with a WindowGroup. Set color scheme to .dark for default dark mode.

1.2 Install Firebase SDK via Swift Package Manager: Add https://github.com/firebase/firebase-ios-sdk. Include modules for Auth, Firestore, and Messaging.

1.3 Configure Firebase in the project:
   - Download GoogleService-Info.plist from Firebase Console and add to project.
   - In AppDelegate or SceneDelegate (if needed), initialize Firebase with `FirebaseApp.configure()`.
   - Enable Firestore offline persistence with `Firestore.settings.isPersistenceEnabled = true`.
   - For speed: Set Firestore cache size to optimize for low latency.

1.4 Set up Firebase Console project:
   - Create a new Firebase project if not exists.
   - Enable Authentication (Email/Password).
   - Set up Firestore database with rules for secure access (e.g., allow read/write if authenticated). Use indexed queries for fast fetches.
   - Enable Cloud Messaging and generate APNs key for push notifications.

1.5 Add capabilities: Enable Push Notifications and Background Modes (Remote notifications) in Xcode Signing & Capabilities. Optimize for quick notifications by using silent pushes where possible.

### 2. Data Models
2.1 Define SwiftData models for local persistence:
   - User: id (String), displayName (String), email (String), profilePictureURL (String?), onlineStatus (Bool), lastSeen (Date?)
   - Message: id (String), senderId (String), content (String), timestamp (Date), status (Enum: sending, sent, delivered, read), isReadBy ( [String] for user IDs)
   - Conversation: id (String), participants ( [String] for user IDs), type (Enum: oneOnOne, group), lastMessage (Message?), unreadCount (Int)
   - Use @Model for SwiftData entities. Ensure models are lightweight for fast querying.

2.2 Define Firestore collections:
   - users: Document per user with fields matching User model.
   - conversations: Document per conversation with participants array, type.
   - messages: Subcollection under conversations, documents with message fields. Index on timestamp for fast sorting.
   - presence: For online status, use a collection or user doc field.

2.3 Implement sync logic between SwiftData and Firestore (basic for MVP, refine later). Use batched writes and efficient listeners to minimize latency.

### 3. Authentication
3.1 Create AuthViewModel with functions for signUp(email, password, displayName) and login(email, password).
   - Use FirebaseAuth to create/auth user.
   - On success, create/update user doc in Firestore.
   - Store user ID in UserDefaults or AppStorage for quick access.

3.2 Build LoginView and SignUpView with SwiftUI forms for email, password, displayName (for sign up).
   - Handle errors, loading states with minimal UI (clean text fields, buttons).
   - Navigate to main app on successful auth. Ensure fast transitions.

3.3 Implement logout functionality in a SettingsView.

3.4 Set up auth state listener to handle user changes and redirect to login if unauthenticated. Make listener efficient to avoid delays.

### 4. User Presence and Profiles
4.1 Implement online/offline detection:
   - Use Reachability or Firebase's .info/connected to monitor network.
   - Update user's onlineStatus in Firestore on app foreground/background/terminate.
   - Listen for presence changes in real-time with low-latency snapshots.

4.2 Create ProfileView to edit displayName and upload profile picture (basic URL for now, implement upload later if time). Use minimalist design: Avatar circle, text fields.

4.3 Fetch and display user profiles in chats (name, avatar placeholder if no pic). Cache avatars locally for fast loading.

### 5. Conversations List
5.1 Create ConversationsViewModel to fetch and listen to user's conversations from Firestore.
   - Query conversations where participants contain current user ID. Use indexes for speed.
   - Sort by lastMessage timestamp.
   - Sync to SwiftData for offline access.

5.2 Build ConversationsView: List of conversations showing participant names (for one-on-one: other user's name; for group: "Group Chat" or custom name), last message preview, timestamp, unread count badge.
   - Show online indicator dot next to names.
   - UI: Clean list rows with circular avatars, bold names, gray previews. Inspired by Signal's chat list.

5.3 Implement search or filter if time, but basic list for MVP. Ensure list loads in <1s.

### 6. Chat View (One-on-One and Group)
6.1 Create ChatViewModel for a specific conversation:
   - Load messages from SwiftData/Firestore, paginate if needed (load last 50 initially).
   - Real-time listener on messages subcollection for new messages. Limit listener scope for performance.
   - Handle sending message: Optimistic insert to UI and SwiftData, then write to Firestore, update status on success/fail.
   - Update read receipts: When viewing message, add user ID to isReadBy in Firestore (batch updates).
   - Typing indicator: Update a ephemeral field in conversation doc (e.g., typingUsers: [String]). Use debounce to reduce writes.

6.2 Build ChatView:
   - Scrollable List or ScrollView for messages, inverted for bottom-to-top. Use LazyVStack for performance with large histories.
   - Message bubbles: Left for others (gray), right for self (blue), with sender name in groups, timestamp, status icons (clock for sending, check for sent/delivered/read). Rounded corners, no heavy shadows.
   - TextField at bottom for input, Send button. Inspired by X DM: Simple input with plus for attachments, voice icon.
   - On typing, update typing status in Firestore (debounce 500ms).
   - Show "User is typing..." at bottom when others typing.
   - Optimistic UI: Show message immediately with "sending" status.
   - Handle images: Basic send/receive with UIImage previews (use Storage for upload/download). Progressive loading for speed.

6.3 Support group chats:
   - When creating conversation, allow adding multiple participants.
   - In ChatView, show sender name above bubbles for groups.
   - Read receipts: Show count or icons for who read. Optimize queries to avoid latency.

### 7. Message Sending and Sync
7.1 Implement sendMessage function:
   - Generate local ID, insert to UI and SwiftData with "sending".
   - Write to Firestore, on success update status to "sent". Use transactions if needed for reliability.
   - If offline, queue in SwiftData, send on reconnect.

7.2 Real-time sync:
   - Use Firestore snapshots for messages, presence. Limit to recent documents for low latency.
   - On snapshot, merge with local data, resolve conflicts (timestamp-based).

7.3 Offline handling:
   - Use SwiftData for all local reads.
   - On reconnect, sync queued messages, fetch missed ones in <1s.
   - UI indicators: "Offline" banner, pending message icons. Minimalist text.

### 8. Push Notifications
8.1 Set up Firebase Messaging:
   - Request notification permission.
   - Get FCM token, store in user doc.

8.2 For MVP, handle foreground notifications:
   - When new message arrives (via Firestore listener or FCM), show in-app alert or update UI instantly.
   - Implement basic FCM data messages for background (if time, but foreground required). Prioritize quick delivery.

8.3 Send notification via Cloud Functions or directly when message sent to offline user. Ensure low latency pushes.

### 9. Performance and UX Polish
9.1 Optimize UI:
   - Ensure 60 FPS scrolling with LazyVStack and efficient view updates.
   - App launch <2s: Preload data in background.
   - Keyboard handling: Adjust scroll on focus without jank.
   - Progressive image loading with placeholders.

9.2 Lifecycle handling:
   - On background: Update presence to offline, maintain connection if possible.
   - On foreground: Reconnect listeners, sync missed messages instantly.
   - Handle force quit: Persist via SwiftData for zero data loss.

9.3 General Optimizations:
   - Use batched Firestore operations to reduce network calls.
   - Cache frequently accessed data (e.g., user profiles).
   - Monitor and log latencies; aim for sub-200ms message delivery.
   - Battery efficiency: Minimize background activity, use FCM for pushes.

### 10. Testing and Deployment
10.1 Test all scenarios:
   - Real-time chat between simulators.
   - Offline: Toggle airplane mode, send/receive.
   - Background/foreground transitions.
   - Rapid messages (test for zero lag).
   - Group with 3+.

10.2 Deploy backend: Ensure Firestore rules secure.
   - Run on simulator.

10.3 Prepare demo: Record video showing features.

10.4 GitHub repo: Commit with README on setup.

## Prioritization
- Core: Auth → Conversations List → One-on-One Chat → Real-Time Sync → Offline → Group → Notifications → Polish.
- Aim for excellent rubric: Sub-200ms delivery, zero lag, full offline queue, smooth group. Reliability first—test edge cases thoroughly.