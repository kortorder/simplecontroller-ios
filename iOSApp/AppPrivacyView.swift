import SwiftUI

/// Kept in the app so the complete policy is readable without a connection.
struct AppPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Simple Controller")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Updated November 21, 2026")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Published by the Simple Controller project.")
                    Text("Simple Controller lets you create and use touch controller profiles on your iPhone. Practice works on your device. Connection mode sends inputs to the console bridge or Windows PC receiver address you configure. No account is required.")
                }

                PrivacyPolicySection("Data stored and used on your device", paragraphs: [
                    "The app saves your profiles, control layouts, reusable settings, calibration summaries, display preferences, quick-start guide progress, bridge address and port, protocol settings, and recovery copies in its local app storage. It also saves a short-lived connection-resume record so it can decide whether to resume a connection after a brief interruption. These records support the app’s features; they are not sent to a developer-operated service.",
                    "Touch positions, timing, contact-size measurements, and force measurements where your device supports them are processed to operate controls and calibrate touch behavior. Raw calibration samples remain in the calibration view’s memory and are discarded when it closes. Calibration summaries you choose to apply or save become part of your saved settings and profiles. The app does not use these measurements to identify you.",
                    "The app does not access your camera, microphone, location, contacts, or photo library. The Camera Follow feature refers to simulated game-camera behavior, not your iPhone camera."
                ])

                PrivacyPolicySection("Imports and exports", paragraphs: [
                    "You choose which files to import through the system file picker. Native backups are processed locally into profiles and settings. Imported Android profiles also preserve a copy of the original file, its display name, and verification metadata in the app’s local storage, so you can recover or export the original later. The preserved original can include fields that the iPhone app does not use, including any information already present in the file.",
                    "Exports happen when you choose to export and select a destination. Export all profiles includes your current profile library and available preserved Android originals. Separate commands can export an unchanged Android original, a reviewed edited Android copy, or a recovery document. Normal profile backups do not include the app’s bridge connection settings or currently held input. An imported original is preserved as supplied, so its contents are not limited by that statement.",
                    "If you select iCloud Drive, another file provider, or a sharing destination, that service or recipient receives the file you selected. Its handling of that file is governed by its own policies and your settings. Simple Controller does not automatically send these exports to its developer."
                ])

                PrivacyPolicySection("Controller connections", paragraphs: [
                    "When you connect a console bridge or Windows PC receiver, the app sends controller state, connection/session tokens, sequence numbers, and protocol messages to the configured IPv4 address and port, normally a device on your local network. Controller state includes supported buttons, sticks, directional-pad input, and trigger values. Windows PC mode also sends assigned keyboard keys, mouse buttons, pointer movement and scrolling. The receiving device replies with readiness and acknowledgment messages. This exchange operates the controller; it does not upload your profile library or imported originals to a developer service.",
                    "The connection uses UDP and has no app-level encryption or authentication. Session tokens keep connection sessions separate; they are not an account or device identifier. The network and receiving device can see the packets and network addresses needed for the connection. Disconnecting or switching to Practice stops the controller connection. You can also revoke Local Network access in iOS Settings.",
                    "A bridge, PC receiver and their hardware or software may have their own data-handling behavior. This policy describes the iPhone app."
                ])

                PrivacyPolicySection("Developer collection, advertising, and analytics", paragraphs: [
                    "This version has no developer-operated data-collection endpoint, advertising SDK, analytics SDK, automatic crash-reporting SDK, or tracking function. The developer does not receive your locally stored profiles, touch measurements, or controller packets through the app. Apple may process App Store, device diagnostic, or backup information under Apple’s own settings and policies."
                ])

                PrivacyPolicySection("External links and optional support", paragraphs: [
                    "Help and privacy links open external websites in your browser only when you choose them. Those sites receive the browser and network information needed to serve their pages and handle it under their own privacy policies.",
                    "If you choose to submit a GitHub issue, the information you post is public and can be read by the project’s maintainers and other visitors. Do not post private files, personal information, or network addresses. The app does not automatically attach profiles, diagnostics, or other app data. Information you submit is retained by GitHub under its policies and account controls; removing app data does not remove a public issue or copies others may have made."
                ])

                PrivacyPolicySection("Retention and deletion", paragraphs: [
                    "Profiles and settings remain in the app’s local storage until changed or the app’s stored data is removed. Deleting a profile removes it from the active profile list but deliberately keeps a local recovery copy. Resetting or restoring profiles may also preserve recovery copies. Preserved Android originals are stored separately and are not erased by deleting their converted profiles. The current version does not provide an in-app command to erase every recovery copy and original.",
                    "Deleting the app through iOS removes its app-managed local data. Offloading the app preserves its documents and data. Exported files, copies you shared, and device backups are separate copies and must be managed where you saved or shared them. Your iCloud or computer device backups may include app data according to your device settings; Simple Controller does not provide its own cloud-sync or backup service. Restoring a backup can restore previously saved app data."
                ])

                PrivacyPolicySection("Questions and policy changes", paragraphs: [
                    "For privacy questions, use the Simple Controller support issues link below. Keep your question free of private information because issues are public. Please do not send a profile or original file unless you want its contents shared with the recipient. This policy will be updated if the app’s data practices change."
                ])

                VStack(alignment: .leading, spacing: 12) {
                    ExternalSupportLink("Privacy questions and support on GitHub", destination: SimpleControllerSupport.issues)
                    ExternalSupportLink("Read the privacy policy online", destination: SimpleControllerSupport.privacy)
                    ExternalSupportLink("Read GitHub’s privacy policy", destination: SimpleControllerSupport.githubPrivacy)
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Privacy policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AppHelpView: View {
    private enum SupportTab: String, CaseIterable { case learn = "Learn", pc = "PC", console = "Console" }
    @State private var selectedTab: SupportTab = .learn

    var body: some View {
        VStack(spacing: 0) {
            Picker("Support topic", selection: $selectedTab) {
                ForEach(SupportTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityIdentifier("support.tabs")
            Form {
                switch selectedTab {
                case .learn: learningSections
                case .pc: pcSections
                case .console: consoleSections
                }
            }
            .id(selectedTab)
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var learningSections: some View {
        Section("Start here") {
            NavigationLink {
                ReplayQuickStartView()
            } label: {
                Label("Quick-start picture guide", systemImage: "rectangle.on.rectangle")
            }
            .accessibilityIdentifier("support.quickStart")
            .accessibilityHint("Replay the short guide without changing your profiles or settings.")
            ExternalSupportLink("Watch the beginner videos", destination: SimpleControllerSupport.videos)
            ExternalSupportLink("Read the full connection FAQ", destination: SimpleControllerSupport.faq)
        }
        Section("Practice, then play") {
            Text("Practice works without a connection or extra hardware. Open Bridge menu → Practice on this iPhone. The highlights and output display let you try a control before using it in a game.")
            Text("Center stops stick movement. Stop releases all phone actions, including holds, repeats and macros. It does not stop independent switches or a separate wheelchair joystick.")
        }
        Section("Make controls comfortable") {
            Text("Tap Edit, move controls, and hold a control to open its settings. Done updates the draft; Save keeps it. Cancel restores the saved layout. Portrait and landscape have separate positions and can use separate sizes.")
            Text("Hold Toggle keeps a button pressed after your chosen hold time. Tap again to release. Stick+ adds actions at chosen stick directions and distances. Button Aim combines a button with stick movement, such as aiming and firing together.")
            Text("Touch Aim uses touch measurements or a manual staged setup. Many iPhones do not measure finger pressure. If two comfortable touches look the same to the phone, use a direct Button Aim pad or a manual ring instead of pressing harder.")
            Text("A Macro Mode button runs its timed sequence from one tap. Stop cancels it. A game may need different delays, button assignments or trigger settings.")
        }
        Section("Profiles and backups") {
            Text("Profiles → Game starters makes an editable copy for a game category. Pages keep related controls together. Use Profiles → Export all profiles to save a backup before a big redesign.")
            Text("Recovery documents keep earlier data when certain changes or restores occur. Imported Android originals are kept separately. Opening this guide does not change those files.")
            NavigationLink("Privacy policy") { AppPrivacyView() }
        }
        Section {
            ExternalSupportLink("Project and source on GitHub", destination: SimpleControllerSupport.project)
            ExternalSupportLink("Ask for help or report a problem", destination: SimpleControllerSupport.issues)
        } header: { Text("Community support") } footer: {
            Text("Links open your browser. GitHub issues are public. Describe the problem without posting private files, passwords or personal network details. The app does not attach your data automatically.")
        }
    }

    @ViewBuilder private var pcSections: some View {
        Section("Wireless Windows PC connection") {
            Label("No Pico or adaptive controller needed", systemImage: "wifi")
            Text("You still need the free compatible PC receiver software and its virtual-gamepad driver. The app connects to that receiver over your local network; it does not discover or install it automatically.")
            ExternalSupportLink("Get the Windows PC receiver and setup guide", destination: SimpleControllerSupport.pcReceiver)
        }
        Section("Set up the connection") {
            SupportStep(number: 1, title: "Start the receiver on Windows", detail: "Follow the receiver guide to install its required ViGEm virtual-gamepad driver. Keep the receiver open. If Windows asks, allow the receiver through the firewall on your trusted private network.")
            SupportStep(number: 2, title: "Use the same network", detail: "Connect the iPhone and PC to the same trusted Wi-Fi or local network. A guest network may block devices from reaching each other.")
            SupportStep(number: 3, title: "Copy the PC address into the app", detail: "Open Bridge menu → Bridge settings. Choose Windows PC • free receiver. Enter the IPv4 address and port displayed by the receiver. Its default port is 42734; use the displayed value if changed.")
            SupportStep(number: 4, title: "Save and connect", detail: "Tap Save and connect. Allow Local Network access if iOS asks. Test an ordinary button, a stick and Stop before opening a game. The saved connection can reconnect when you reopen the app.")
        }
        Section("What works") {
            Text("The PC route supports the receiver’s Xbox buttons, sticks and adjustable LT/RT, plus keyboard, mouse and touchpad actions. The original receiver does not provide Xbox Guide or Share. Game controls and accepted inputs vary by game.")
            Text("A saved 50% trigger value stays adjustable on this PC route. That is different from the Xbox Adaptive Controller’s USB-button mode, which presses LT/RT fully.")
        }
        Section("If it does not connect") {
            Text("Check that the receiver is running, that the IP address and port match, and that both devices are on the same network. Check Windows firewall and iOS Settings → Privacy & Security → Local Network. Do not expose the receiver to the public internet.")
            ExternalSupportLink("PC troubleshooting and FAQ", destination: SimpleControllerSupport.faq)
        }
    }

    @ViewBuilder private var consoleSections: some View {
        Section("Choose a compatible route") {
            Text("Console connection needs a separate compatible adaptive controller and bridge connection device. The tested setup here is Xbox with an Xbox Adaptive Controller. Do not assume that the same USB firmware works with every console.")
            ExternalSupportLink("Pico Wi-Fi bridge: firmware and console setup", destination: SimpleControllerSupport.wifiBridge)
            ExternalSupportLink("Complete hardware and connection FAQ", destination: SimpleControllerSupport.faq)
        }
        Section("Xbox: phone controls") {
            SupportStep(number: 1, title: "Use the matching Pico", detail: "Use a Raspberry Pi Pico W or Pico WH with the RP2040 chip and a micro-USB data cable. The ordinary Pico has no Wi-Fi. Pico 2 W needs different firmware; do not flash the RP2040 image onto it.")
            SupportStep(number: 2, title: "Install the bridge firmware", detail: "Follow the Pico Wi-Fi bridge guide on GitHub to enter your 2.4 GHz Wi-Fi settings and install firmware. Changing a setting in this app does not program the board.")
            SupportStep(number: 3, title: "Connect the Adaptive Controller", detail: "Update it in Xbox Accessories. Connect the phone Pico to its left side USB port. Use the compatible rear DC power supply specified by the guide so the side USB port can power the bridge.")
            SupportStep(number: 4, title: "Connect the phone", detail: "Keep the iPhone and Pico on the same trusted network. In Bridge settings choose SCX2, enter the Pico’s IPv4 address and port (normally 42736), then Save and connect. Allow Local Network access.")
            SupportStep(number: 5, title: "Choose trigger output", detail: "For USB full presses, use matching USB-button firmware, choose USB buttons (full press), and map X1 to LT and X2 to RT in the active Xbox Accessories profile. Test both press and release. Partial pressure needs a different supported hardware route.")
        }
        Section("Permobil / Omni2 chair joystick") {
            Text("The chair connection uses a second Pico W or WH with separate Omni2 firmware. It pairs directly with a compatible Omni2 Bluetooth mouse slot and acts as a stick through the Adaptive Controller’s right USB port. A chair without a compatible Bluetooth mouse output may need a different solution.")
            Text("Follow the guide while the chair is parked and the Omni2 is in Bluetooth mouse mode. Keep the phone and chair firmware separate. Nudge buttons are optional and can be turned off.")
            ExternalSupportLink("Permobil / Omni2 joystick bridge guide", destination: SimpleControllerSupport.chairBridge)
        }
        Section("PlayStation") {
            Text("A direct Pico-to-PlayStation setup has not been verified for this project. The Xbox Adaptive Controller bridge firmware does not make the Pico an authenticated PS5 controller, and Sony’s Access controller is not a drop-in replacement for the Xbox USB route.")
            Text("A PlayStation setup needs a separately compatible controller/adapter route for the exact console and game. Check the FAQ and the adapter maker’s current compatibility before buying anything. We do not label an untested route as plug and play.")
            ExternalSupportLink("Current PlayStation compatibility notes", destination: SimpleControllerSupport.faq)
        }
    }
}

private struct SupportStep: View {
    let number: Int
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(number). \(title)").font(.headline)
            Text(detail).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct PrivacyPolicySection: View {
    let title: String
    let paragraphs: [String]

    init(_ title: String, paragraphs: [String]) {
        self.title = title
        self.paragraphs = paragraphs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(paragraphs.indices, id: \.self) { index in
                Text(paragraphs[index])
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ExternalSupportLink: View {
    let title: String
    let destination: URL

    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            Label {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.up.right.square")
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityHint("Opens a web page in your browser.")
    }
}

