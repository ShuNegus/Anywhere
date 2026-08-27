//
//  AnywhereApp.swift
//  Anywhere
//
//  Created by NodePassProject on 1/23/26.
//

import SwiftUI

@main
struct AnywhereApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CloudBlobSync.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The scene can be created while the app is in the background, and
                // `onChange` only fires on transitions, so seed the flag once here.
                .task { AWCore.setAppInForeground(scenePhase == .active) }
        }
        .onChange(of: scenePhase) { _, newValue in
            AWCore.setAppInForeground(newValue == .active)
        }
    }
}
