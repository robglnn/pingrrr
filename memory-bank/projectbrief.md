# Project Brief – Pingrrr

## Overview
Pingrrr is an iOS messaging app built with Swift and SwiftUI that targets the “International Communicator” persona. The MVP must ship today (October 21, 2025) and deliver a production-grade real-time chat experience with Firebase providing authentication, Firestore storage, Cloud Messaging, and Cloud Functions.

## Core Objectives
- Sub-200 ms real-time delivery for one-on-one and group chats.
- Reliable offline persistence with SwiftData, including queued sends and instant resync on reconnect.
- Dark-mode-only, Signal/X-inspired UI that remains performant at 60 FPS.
- AI-enhanced communication (translation, tone adjustments, cultural context) built on Cloud Functions + OpenAI, integrated via the Vercel AI SDK.
- Foundation ready for deployment: runs on simulator with deployed Firebase backend, supports push notifications, and includes documentation/demos post-MVP.

## Scope
- **In Scope (MVP)**: Auth, presence, conversations, messaging (1:1 + group), message state (read receipts, optimistic updates), offline handling, FCM foreground pushes, SwiftData sync, minimal profile management, typing indicators, performance optimizations.
- **Future (Post-MVP)**: Advanced AI tooling refinement, richer media handling, comprehensive push notification flows, TestFlight distribution artifacts, marketing assets.

## Constraints & Deadlines
- MVP deadline: October 21, 2025 @ 11:59 PM EDT.
- Must satisfy `MVPcriticalrequirements.md` and `MVPtasks.md` checklists.
- Prioritize reliability and latency over non-essential polish.

## Success Criteria
- Meets all MVP requirements and testing scenarios outlined in `PRD.md`.
- Demonstrates <2 s cold start, stable 60 FPS UI, and lossless offline resume.
- AI features achieve high accuracy (<2 s response) without compromising core chat performance.

