// Luna — Profile Switcher Bubble
// Sits to the left of the address bar. Click = dropdown. Vertical swipe = carousel cycle.
import SwiftUI
import AppKit

// MARK: - ProfileSwitcherView

struct ProfileSwitcherView: View {
    @ObservedObject var profileManager: ProfileManager
    /// Called when the user picks a different profile; caller handles tab swap.
    let onSwitch: (BrowserProfile) -> Void
    /// Called when user picks "Open in New Window" for a profile.
    let onOpenInNewWindow: (BrowserProfile) -> Void

    @State private var dropdownOpen: Bool = false
    @State private var swipeAccumulator: CGFloat = 0
    @State private var showNewProfileForm: Bool = false
    @State private var newProfileName: String = ""
    @State private var newProfileColorId: String = ProfileColor.presets[0].id
    @State private var profileToDelete: BrowserProfile? = nil
    @State private var showDeleteConfirm: Bool = false

    private var active: BrowserProfile { profileManager.activeProfile }

    var body: some View {
        ZStack {
            // Hit area for swipe gesture
            bubbleButton
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            // Vertical swipe to cycle profiles
                            let dy = value.translation.height
                            if abs(dy - swipeAccumulator) >= 44 {
                                let direction = (dy - swipeAccumulator) > 0 ? 1 : -1
                                cycleProfile(direction: direction)
                                swipeAccumulator = dy
                            }
                        }
                        .onEnded { _ in swipeAccumulator = 0 }
                )
        }
        .popover(isPresented: $dropdownOpen, arrowEdge: .bottom) {
            profileDropdown
        }
        .confirmationDialog(
            "Delete profile?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: profileToDelete
        ) { profile in
            Button("Delete Profile & Data", role: .destructive) {
                deleteProfile(profile)
            }
            Button("Cancel", role: .cancel) {
                showDeleteConfirm = false
            }
        } message: { profile in
            Text("Permanently delete \"\(profile.name)\"? All browsing history, cookies, and login sessions for this profile will be removed. This cannot be undone.")
        }
        .onChange(of: showDeleteConfirm) { _, isShown in
            if !isShown { profileToDelete = nil }
        }
    }

    // MARK: - Bubble button

    private var bubbleButton: some View {
        Button(action: { dropdownOpen.toggle() }) {
            ZStack {
                Circle()
                    .fill(active.profileColor.color)
                    .frame(width: 26, height: 26)
                Text(active.name.prefix(1).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .help("Profile: \(active.name) — Click to switch, swipe up/down to cycle")
        .accessibilityLabel("Active profile: \(active.name)")
    }

    // MARK: - Dropdown popover

    private var profileDropdown: some View {
        VStack(spacing: 0) {
            // Header
            Text("Profiles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Divider()

            // Profile list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(profileManager.profiles) { profile in
                        ProfileRowView(
                            profile: profile,
                            isActive: profile.id == profileManager.activeProfileId,
                            onSelect: {
                                if profile.id != profileManager.activeProfileId {
                                    dropdownOpen = false
                                    onSwitch(profile)
                                } else {
                                    dropdownOpen = false
                                }
                            },
                            onOpenNewWindow: {
                                dropdownOpen = false
                                onOpenInNewWindow(profile)
                            },
                            onDelete: profileManager.profiles.count > 1 ? {
                                profileToDelete = profile
                                showDeleteConfirm = true
                            } : nil
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 280)

            Divider()

            // New profile inline form or button
            if showNewProfileForm {
                newProfileForm
            } else {
                Button(action: { showNewProfileForm = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.accentColor)
                        Text("New Profile")
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - New profile inline form

    private var newProfileForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Profile")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            TextField("Profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .onSubmit { commitNewProfile() }

            // Color swatches
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProfileColor.presets) { color in
                        Button(action: { newProfileColorId = color.id }) {
                            ZStack {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 22, height: 22)
                                if newProfileColorId == color.id {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2)
                                        .frame(width: 22, height: 22)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    showNewProfileForm = false
                    newProfileName = ""
                    newProfileColorId = ProfileColor.presets[0].id
                }
                .buttonStyle(.bordered)

                Button("Create") { commitNewProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Actions

    private func cycleProfile(direction: Int) {
        let ids = profileManager.profiles.map(\.id)
        guard let current = ids.firstIndex(of: profileManager.activeProfileId) else { return }
        let next = (current + direction + ids.count) % ids.count
        let nextProfile = profileManager.profiles[next]
        if nextProfile.id != profileManager.activeProfileId {
            onSwitch(nextProfile)
        }
    }

    private func commitNewProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let p = profileManager.addProfile(name: name, colorId: newProfileColorId)
        showNewProfileForm = false
        newProfileName = ""
        newProfileColorId = ProfileColor.presets[0].id
        dropdownOpen = false
        onSwitch(p)
    }

    private func deleteProfile(_ profile: BrowserProfile) {
        let wasActive = profile.id == profileManager.activeProfileId
        profileManager.deleteProfile(profileId: profile.id) {
            if wasActive {
                onSwitch(profileManager.activeProfile)
            }
        }
        showDeleteConfirm = false
    }
}

// MARK: - ProfileRowView

private struct ProfileRowView: View {
    let profile: BrowserProfile
    let isActive: Bool
    let onSelect: () -> Void
    let onOpenNewWindow: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Avatar circle
            ZStack {
                Circle()
                    .fill(profile.profileColor.color)
                    .frame(width: 28, height: 28)
                Text(profile.name.prefix(1).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if isActive {
                    Text("Active")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
            }

            // Context menu via right-click (the row itself handles left-click to select)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(action: onOpenNewWindow) {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            if let onDelete = onDelete {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Profile…", systemImage: "trash")
                }
            }
        }
        .padding(.horizontal, 6)
    }
}
