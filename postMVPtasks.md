# Post-MVP Tasks for Pingrrr iOS App

## Overview
This document outlines the step-by-step tasks to implement the post-MVP requirements for Pingrrr, focusing on AI features for the International Communicator persona. Build upon the solid MVP foundation, ensuring reliability, speed, and low latency in AI integrations. The goal is to achieve excellent rubric scores in AI Features Implementation (30 points) and Technical Implementation (10 points).

**Key Goals for Post-MVP:**
- Implement all 5 required AI features with 90%+ accuracy and <2s response times.
- Add one advanced AI capability: Context-Aware Smart Replies (Option A).
- Use Option 2: Contextual AI Features (embedded in conversations via long-press or toolbar).
- Prioritize reliability and speed: Fast AI calls, caching for common operations, minimal UI lag.
- Target Early Submission (Friday) for core AI, Final (Sunday) for polish and advanced.

**Tech Stack Additions:**
- AI: OpenAI GPT-4 via Firebase Cloud Functions.
- Framework: Vercel AI SDK for agent development, tool calling.
- RAG: Implement retrieval from conversation history stored in Firestore/SwiftData.
- UI: Maintain Signal/X-inspired dark mode, minimalist design; integrate AI actions seamlessly (e.g., long-press menu with "Translate", "Explain Slang").

**Notes:**
- Assume MVP is complete: Core messaging, auth, sync, etc.
- Test AI with edge cases: Mixed languages, slang, cultural nuances, empty histories.
- Optimize for performance: Cache translations, use streaming responses if possible.
- UI Guidelines: Default dark mode, clean bubbles; add subtle AI indicators (e.g., globe icon for translations).

## Task Breakdown

### 1. AI Backend Setup
1.1 Set up Firebase Cloud Functions:
   - Create a function for AI calls (e.g., `aiProcess`) that handles OpenAI API requests securely.
   - Store OpenAI API key in Function environment variables.
   - Implement rate limiting and error handling to prevent abuse/costs.

1.2 Integrate Vercel AI SDK:
   - Add Vercel AI SDK via Swift Package Manager (if available) or manual integration.
   - Create an AI agent with tools for translation, detection, etc.
   - Define tools: e.g., translate(text, targetLang), detectLanguage(text), getCulturalHint(phrase, lang).

1.3 Implement RAG Pipeline:
   - Function to retrieve last N messages from Firestore/SwiftData as context.
   - Format history for LLM prompts (e.g., "User: msg\nAssistant: ...").
   - Store user preferences (e.g., preferred languages) in Firestore user doc.

### 2. AI ViewModel and State Management
2.1 Create AIManager or extend ChatViewModel with AI capabilities:
   - Handle conversation history retrieval.
   - Manage AI states: loading, error, success.
   - Implement memory: Store recent AI responses in SwiftData for quick recall.
   - Error recovery: Retry failed calls, fallback to basic text.

2.2 User Preferences:
   - Add settings for default languages, formality levels.
   - Store in Firestore, sync to local.

### 3. Required AI Features Implementation
Implement each as contextual actions: Long-press on message → menu with AI options.

3.1 Real-time Translation (Inline):
   - On send/receive, optionally auto-translate if different languages detected.
   - UI: Show original + translated below/aside in bubble (toggleable).
   - Call AI: Prompt GPT-4 "Translate [text] to [targetLang] naturally."
   - Optimize: Cache common phrases.

3.2 Language Detection & Auto-Translate:
   - On message receive, detect lang via AI tool.
   - If != user's preferred, auto-translate and show inline.
   - Prompt: "Detect language of [text] and translate to [userLang] if different."

3.3 Cultural Context Hints:
   - Long-press → "Get Cultural Hint".
   - Prompt: "Provide cultural context for [phrase] in [lang] context."
   - UI: Popover or inline note with hint.

3.4 Formality Level Adjustment:
   - During translation or reply drafting, adjust tone.
   - Prompt: "Translate [text] to [lang] with [formal/informal] formality."
   - UI: Option in settings or per-chat.

3.5 Slang/Idiom Explanations:
   - Long-press on word/phrase → "Explain Slang".
   - Prompt: "Explain the slang/idiom '[phrase]' in [lang] simply."
   - UI: Tooltip or modal with explanation.

### 4. Advanced AI Capability: Context-Aware Smart Replies
4.1 Implement Smart Replies:
   - In ChatView, above input: Suggest 3+ replies based on history.
   - Learns style: Use RAG with past user messages to match tone/language.
   - Prompt: "Generate 3 smart replies in [lang] matching my style: [history summary]. For message: [lastMsg]."
   - UI: Horizontal scrollable suggestions; tap to insert.

4.2 Multi-Language Support:
   - Handle replies in multiple languages based on conversation.
   - Test accuracy with user feedback loop (e.g., thumbs up/down to refine).

4.3 Agent Workflow:
   - Use Vercel SDK for multi-step: Detect lang → Adjust formality → Generate reply.
   - Maintain context across interactions.

### 5. AI UI Integration
5.1 Contextual Menus:
   - Long-press Gesture on message bubbles: Menu with AI actions.
   - Toolbar in ChatView: Buttons for quick AI (e.g., translate all).

5.2 Loading and Error States:
   - Spinners for AI calls (<2s target).
   - Error messages: "AI failed, retry?" Minimalist alerts.

5.3 Hybrid Approach if Time:
   - Add dedicated AI chat for complex queries.

### 6. Performance and Polish
6.1 Optimize AI Calls:
   - Batch if possible; use streaming for longer responses.
   - Cache: Store translations in Firestore for reuse.
   - Latency: Aim <2s simple, <8s advanced.

6.2 Testing:
   - Edge cases: Multilingual chats, idioms, poor network (queue AI if offline?).
   - Accuracy: Test with diverse languages (English, Spanish, etc.).
   - Rubric: 90%+ command success, clean integration.

6.3 Bonus if Time:
   - Voice transcription with AI.
   - Dark mode polish.

### 7. Final Deliverables Preparation
7.1 Update Repo: Add AI code, update README with AI setup.
7.2 Demo Video: Show AI features in action, advanced replies.
7.3 Deployment: Update TestFlight with AI version.
7.4 Persona Brainlift: Explain feature alignment.
7.5 Social Post: Share progress.

## Prioritization
- Core AI: Required 5 features → Advanced Replies → Polish.
- Focus on persona fit: Solve language barriers effectively.
- Ensure no stability loss: Thorough testing on real devices.