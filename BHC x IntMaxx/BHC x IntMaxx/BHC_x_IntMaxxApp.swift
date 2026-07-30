//
//  BHC_x_IntMaxxApp.swift
//  BHC x IntMaxx
//
//  Created by Beck Jungwhan on 7/29/26.
//

import SwiftUI
import SwiftData

@main
struct BHC_x_IntMaxxApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
