import SwiftUI

// Profiles: sets of tabs, and only that. Sign-ins, history, passwords and
// extensions are the same in every one — a profile is "the tabs for this
// piece of work", not another person.
//
// The one on screen is the browser's `tabs`. The others are parked: their
// tabs asleep as idle tabs sleep (Sleep.swift), holding an address, their
// history and a picture, and no web view — a profile you are not looking at
// costs a few lines in session.json and nothing at all at launch. Coming back
// puts its tabs in the row at once and loads only the one you were on. The
// switching itself is in Browser.swift, beside the rest of the tab handling;
// this file is what asks and what shows.

extension Browser {
    /// A name asked for in a sheet, the old one in the field if there is one.
    func askProfileName(_ title: String, current: String = "", then done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.stringValue = current
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { answer in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard answer == .alertFirstButtonReturn, !name.isEmpty else { return }
            done(name)
        }
        if let window = Links.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    func newProfile() {
        askProfileName("New profile") { [weak self] name in self?.addProfile(named: name) }
    }

    /// The one on screen, or any by index.
    func renameProfile(_ index: Int? = nil) {
        let which = index ?? profile
        guard profileNames.indices.contains(which) else { return }
        askProfileName("Rename profile", current: profileNames[which]) { [weak self] name in
            self?.renameProfile(which, to: name)
        }
    }

    func deleteCurrentProfile() { askToDelete(profile) }

    /// After a word: its tabs close with it.
    func askToDelete(_ index: Int) {
        guard profileNames.count > 1, profileNames.indices.contains(index) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(profileNames[index])”?"
        let count = tabCount(in: index)
        alert.informativeText = count == 0 ? "It has no tabs." : count == 1 ? "Its one tab closes." : "Its \(count) tabs close."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] answer in
            guard answer == .alertFirstButtonReturn, let self else { return }
            deleteProfile(index)
        }
        if let window = Links.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// The profile you are in, as a small pill with the others behind it. Only
/// there once there is more than one: a browser with one profile has no
/// reason to say so.
struct ProfileDoor: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if browser.profileNames.count > 1 {
            Menu {
                ForEach(Array(browser.profileNames.enumerated()), id: \.offset) { index, name in
                    Button { browser.switchProfile(to: index) } label: {
                        if index == browser.profile {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button("New Profile…") { browser.newProfile() }
                Button("Rename…") { browser.renameProfile() }
                Button("Delete") { browser.deleteCurrentProfile() }
            } label: {
                Text(browser.profileNames[browser.profile])
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.wash.opacity(0.55))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Profile   ⌃1 ⌃2 …")
        }
    }
}
