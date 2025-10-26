Now were ready to work on our AI feature set. reference our tasks.md and post MVP documentation. please ask me any questions you have and summarize the architecture plan on how to best build this out

requirements
All 5 required AI features implemented and working excellently
Features genuinely useful for persona's (the International Communicator) pain points
Natural language commands work 96%+ of the time
Fast response times (<1.5s for simple commands)
Clean UI integration (contextual menus, chat interface, or hybrid)
Clear loading states and error handling

our required AI features, 

1R eal-time translation accurate and natural
2 Language detection works automatically
3 Cultural context hints actually helpful
4 Formality adjustment produces appropriate tone
5 Slang/idiom explanations clear

our vercel agents must achieve:
Advanced capability fully implemented and impressive
Multi-Step Agent: Executes complex workflows autonomously, maintains context across 5+ steps, handles edge cases gracefully
Proactive Assistant: Monitors conversations intelligently, triggers suggestions at right moments, learns from user feedback
Context-Aware Smart Replies: Learns user style accurately, generates authentic-sounding replies, provides 3+ relevant options
Intelligent Processing: Extracts structured data accurately, handles multilingual content, presents clear summaries
Uses required agent framework correctly (if applicable)
Response times meet targets (<15s for agents, <8s for others)
Seamless integration with other features

 Each feature demonstrates daily usefulness and contextual value

----
----
AI Features Implementation
All AI features should be built using LLMs (GPT-4), function calling/tool use, and RAG pipelines for accessing conversation history. ---This is not about training ML models—it's about leveraging existing AI capabilities through prompting and tool integration.---
Technical Implementation
AI Architecture Options:
Option 1: AI Chat Interface A dedicated AI assistant in a special chat where users can:
Ask questions about their conversations
Request actions ("Translate my last message to Spanish")
Get proactive suggestions
Option 2: Contextual AI Features AI features embedded directly in conversations:
Long-press message → translate/summarize/extract action
Toolbar buttons for quick AI actions
Inline suggestions as users type
Option 3: Hybrid Approach Both a dedicated AI assistant AND contextual features
--- we are going with option 3. a dedicated chat  with an AI Assistant will be at the top of the Chats window at all times for all users who log in.
then we will include the contextual features in all chats for formality adjustment, cultural context hints, language detection and auto translate, real time translation inline, slang and idiom explanations etc.

AI Integration Requirements:
The following agent framework is recommended:
AI SDK by Vercel - streamlined agent development with tool calling
OpenAI GPT-4 (called from Cloud Functions), we may also switch to a grok LLM at some later point.
Function calling / tool use

Your agent should have:
Conversation history retrieval (RAG pipeline)
User preference storage
Function calling capabilities
Memory/state management across interactions
Error handling and recovery

-------
-------

We are designing this to help a persona called the International Communicator, this is our main user base

International Communicator
People with friends/family/colleagues speaking different languages.

their pain points:
• Language barriers 
• Translation nuances 
• Copy-paste overhead 
• Learning difficulty

The required features we are building for them:
1. Real-time translation (inline) 
2. Language detection & auto-translate 
3. Cultural context hints 
4. Formality level adjustment 
5. Slang/idiom explanations
6. Context-Aware Smart Replies: Learns your style in multiple languages  7. Intelligent Processing: Extracts structured data from multilingual conversations

please ask me if you have any questions. 