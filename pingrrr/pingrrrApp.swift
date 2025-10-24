//
//  pingrrrApp.swift
//  pingrrr
//
//  Created by robert on 10/20/25.
//

import SwiftUI
import SwiftData

@main
struct PingrrrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        do {
            let schema = Schema([
                UserEntity.self,
                ConversationEntity.self,
                MessageEntity.self,
                ConversationPreferenceEntity.self
            ])

            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false
            )

            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }
}
