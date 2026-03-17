//
//  LumaApp.swift
//  Luma
//
//  Root app entry for the Luma browser.
//
import SwiftUI

@main
struct LumaApp: App {
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        Settings {
            SettingsView()
        }
    }
}
