// Luna — Profile Manager
// Manages browser profiles: isolated history, cookies, and identity.
// Each profile gets its own WKWebsiteDataStore (non-persistent UUID-keyed store).
// The Default profile uses the system persistent store for backwards compatibility.
import Foundation
import SwiftUI
import WebKit
import Combine

// MARK: - Profile color presets

struct ProfileColor: Identifiable, Codable, Equatable {
    let id: String   // e.g. "indigo"
    let r: Double
    let g: Double
    let b: Double

    var color: Color { Color(red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }

    /// 10–15% lighter variant for inactive tabs
    var lightVariant: Color {
        Color(red: min(1, r + 0.12), green: min(1, g + 0.12), blue: min(1, b + 0.12))
    }

    static let presets: [ProfileColor] = [
        ProfileColor(id: "indigo",   r: 0.29, g: 0.33, b: 0.80),
        ProfileColor(id: "violet",   r: 0.55, g: 0.27, b: 0.85),
        ProfileColor(id: "rose",     r: 0.85, g: 0.25, b: 0.42),
        ProfileColor(id: "amber",    r: 0.85, g: 0.55, b: 0.10),
        ProfileColor(id: "emerald",  r: 0.13, g: 0.65, b: 0.45),
        ProfileColor(id: "sky",      r: 0.18, g: 0.60, b: 0.86),
        ProfileColor(id: "slate",    r: 0.30, g: 0.35, b: 0.42),
        ProfileColor(id: "coral",    r: 0.90, g: 0.40, b: 0.30),
        ProfileColor(id: "teal",     r: 0.10, g: 0.60, b: 0.60),
        ProfileColor(id: "graphite", r: 0.22, g: 0.22, b: 0.24),
    ]

    init(id: String, r: Double, g: Double, b: Double) {
        self.id = id; self.r = r; self.g = g; self.b = b
    }
}

// MARK: - BrowserProfile

struct BrowserProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorId: String   // references ProfileColor.id
    /// true = uses WKWebsiteDataStore.default() (legacy / Default profile)
    var isDefault: Bool

    static func == (lhs: BrowserProfile, rhs: BrowserProfile) -> Bool { lhs.id == rhs.id }

    var profileColor: ProfileColor {
        ProfileColor.presets.first { $0.id == colorId } ?? ProfileColor.presets[0]
    }

    // Convenience for the toolbar tint: a color slightly transparent over dark BG
    var toolbarTint: Color { profileColor.color.opacity(0.18) }
    var toolbarTintStrong: Color { profileColor.color.opacity(0.30) }
    var accentSolid: Color { profileColor.color }
}

// MARK: - ProfileTabState
// Stores which tabs were open per profile so switching preserves them.

struct ProfileTabSnapshot: Codable {
    struct TabEntry: Codable {
        let id: UUID
        let urlString: String?
        let title: String
    }
    var tabs: [TabEntry]
    var activeTabId: UUID?
}

// MARK: - ProfileManager

final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published private(set) var profiles: [BrowserProfile] = []
    @Published private(set) var activeProfileId: UUID = UUID()   // overwritten immediately in init

    // Data store cache: profile UUID → WKWebsiteDataStore
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    // In-memory suspended tab snapshots (profile → snapshot)
    private var suspendedSnapshots: [UUID: ProfileTabSnapshot] = [:]
    // Timers for 5-min suspension
    private var suspensionTimers: [UUID: DispatchWorkItem] = [:]

    private let profilesKey = "luma_profiles_v1"
    private let activeProfileKey = "luma_active_profile_v1"

    private init() {
        let saved = Self.loadProfiles()
        if saved.isEmpty {
            let def = BrowserProfile(
                id: UUID(),
                name: "Personal",
                colorId: "indigo",
                isDefault: true
            )
            profiles = [def]
            activeProfileId = def.id
            saveProfiles()
        } else {
            profiles = saved
            if let storedActive = UserDefaults.standard.string(forKey: "luma_active_profile_v1"),
               let uuid = UUID(uuidString: storedActive),
               saved.contains(where: { $0.id == uuid }) {
                activeProfileId = uuid
            } else {
                activeProfileId = saved[0].id
            }
        }
    }

    var activeProfile: BrowserProfile {
        profiles.first { $0.id == activeProfileId } ?? profiles[0]
    }

    // MARK: - Data store

    func dataStore(for profileId: UUID) -> WKWebsiteDataStore {
        if let cached = dataStores[profileId] { return cached }
        let profile = profiles.first { $0.id == profileId }
        let store: WKWebsiteDataStore
        if profile?.isDefault == true {
            store = .default()
        } else {
            // Persistent non-default store keyed by profile UUID
            if #available(macOS 14.0, *) {
                store = WKWebsiteDataStore(forIdentifier: profileId)
            } else {
                // Fallback for macOS 13: use non-persistent (no cookie persistence pre-14)
                store = .nonPersistent()
            }
        }
        dataStores[profileId] = store
        return store
    }

    var activeDataStore: WKWebsiteDataStore {
        dataStore(for: activeProfileId)
    }

    // MARK: - Switch profile

    /// Switch to a profile. Caller is responsible for suspending/restoring tab state.
    func switchTo(profileId: UUID) {
        guard profiles.contains(where: { $0.id == profileId }) else { return }
        activeProfileId = profileId
        UserDefaults.standard.set(profileId.uuidString, forKey: activeProfileKey)
    }

    // MARK: - CRUD

    func addProfile(name: String, colorId: String) -> BrowserProfile {
        let p = BrowserProfile(id: UUID(), name: name, colorId: colorId, isDefault: false)
        profiles.append(p)
        saveProfiles()
        return p
    }

    func rename(profileId: UUID, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].name = name
        saveProfiles()
    }

    func recolor(profileId: UUID, colorId: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].colorId = colorId
        saveProfiles()
    }

    /// Deletes a profile and wipes all its website data.
    func deleteProfile(profileId: UUID, completion: @escaping () -> Void) {
        guard profiles.count > 1 else { return }  // always keep at least one
        let store = dataStore(for: profileId)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.profiles.removeAll { $0.id == profileId }
                self.dataStores.removeValue(forKey: profileId)
                self.suspendedSnapshots.removeValue(forKey: profileId)
                if self.activeProfileId == profileId {
                    self.activeProfileId = self.profiles[0].id
                }
                self.saveProfiles()
                completion()
            }
        }
    }

    // MARK: - Tab suspension

    func saveSnapshot(_ snapshot: ProfileTabSnapshot, for profileId: UUID) {
        suspendedSnapshots[profileId] = snapshot
    }

    func snapshot(for profileId: UUID) -> ProfileTabSnapshot? {
        suspendedSnapshots[profileId]
    }

    /// Schedule suspension of a profile's webviews after 5 minutes.
    /// Call this when switching away from a profile.
    func scheduleSuspension(for profileId: UUID, action: @escaping () -> Void) {
        // Cancel any existing timer
        suspensionTimers[profileId]?.cancel()
        let work = DispatchWorkItem(block: action)
        suspensionTimers[profileId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    func cancelSuspension(for profileId: UUID) {
        suspensionTimers[profileId]?.cancel()
        suspensionTimers.removeValue(forKey: profileId)
    }

    // MARK: - Persistence

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(activeProfileId.uuidString, forKey: activeProfileKey)
    }

    private static func loadProfiles() -> [BrowserProfile] {
        guard let data = UserDefaults.standard.data(forKey: "luma_profiles_v1"),
              let decoded = try? JSONDecoder().decode([BrowserProfile].self, from: data) else {
            return []
        }
        return decoded
    }
}
