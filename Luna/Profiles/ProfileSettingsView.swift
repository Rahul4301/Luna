// Luna — Profiles Settings Tab
import SwiftUI

struct ProfileSettingsView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var editingProfile: BrowserProfile? = nil
    @State private var editName: String = ""
    @State private var editColorId: String = ""
    @State private var profileToDelete: BrowserProfile? = nil
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Profiles")
                    .font(.largeTitle)
                    .padding(.bottom, 4)

                Text("Each profile has its own browsing history, cookies, and login sessions. Switching profiles is like using a completely separate browser.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                // Profile list
                VStack(spacing: 12) {
                    ForEach(profileManager.profiles) { profile in
                        profileCard(profile)
                    }
                }

                Divider()

                // Add new profile button
                Button(action: addNewProfile) {
                    Label("Add Profile", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(24)
        }
        // Inline edit sheet
        .sheet(item: $editingProfile) { profile in
            editSheet(for: profile)
        }
        // Delete confirmation (isPresented + presenting — item: overload not on all macOS SDKs)
        .confirmationDialog(
            "Delete profile?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: profileToDelete
        ) { profile in
            Button("Delete Profile & Data", role: .destructive) {
                profileManager.deleteProfile(profileId: profile.id) {
                    showDeleteConfirm = false
                }
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

    // MARK: - Profile card

    private func profileCard(_ profile: BrowserProfile) -> some View {
        HStack(spacing: 14) {
            // Avatar
            ZStack {
                Circle()
                    .fill(profile.profileColor.color)
                    .frame(width: 40, height: 40)
                Text(profile.name.prefix(1).uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                    if profile.id == profileManager.activeProfileId {
                        Text("Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(profile.profileColor.color))
                    }
                }
                Text(profile.isDefault ? "Default profile" : "Custom profile")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Edit button
            Button("Edit") {
                editName = profile.name
                editColorId = profile.colorId
                editingProfile = profile
            }
            .buttonStyle(.bordered)

            // Delete (disabled for last profile)
            if profileManager.profiles.count > 1 {
                Button(role: .destructive) {
                    profileToDelete = profile
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    profile.id == profileManager.activeProfileId
                        ? profile.profileColor.color.opacity(0.5)
                        : Color.clear,
                    lineWidth: 1.5
                )
        )
    }

    // MARK: - Edit sheet

    private func editSheet(for profile: BrowserProfile) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Profile")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline.weight(.medium))
                TextField("Profile name", text: $editName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Color")
                    .font(.subheadline.weight(.medium))

                let columns = Array(repeating: GridItem(.fixed(36), spacing: 10), count: 5)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ProfileColor.presets) { color in
                        Button(action: { editColorId = color.id }) {
                            ZStack {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 32, height: 32)
                                if editColorId == color.id {
                                    Circle()
                                        .stroke(Color.primary.opacity(0.8), lineWidth: 2.5)
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { editingProfile = nil }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    let name = editName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    profileManager.rename(profileId: profile.id, to: name)
                    profileManager.recolor(profileId: profile.id, colorId: editColorId)
                    editingProfile = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340, height: 380)
    }

    // MARK: - Add new profile

    private func addNewProfile() {
        let count = profileManager.profiles.count + 1
        let colorId = ProfileColor.presets[count % ProfileColor.presets.count].id
        let p = profileManager.addProfile(name: "Profile \(count)", colorId: colorId)
        editName = p.name
        editColorId = p.colorId
        editingProfile = p
    }
}
