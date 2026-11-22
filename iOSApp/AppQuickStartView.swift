import SwiftUI

private struct QuickStartPage: Identifiable {
    enum Illustration { case practice, stick, aim, drive, layout, pc, console, support }
    let id: Int
    let title: String
    let subtitle: String
    let detail: String
    let illustration: Illustration
    let imageDescription: String

    static let all: [Self] = [
        .init(id: 0, title: "Make one finger do more", subtitle: "Start in Practice. Nothing is sent to a game.",
              detail: "Touch a button or move a stick to see what it does. Stop releases held actions, repeats and macros. Choose a ready-made game starter after this guide.", illustration: .practice,
              imageDescription: "A small controller with a stick, A button and Stop button. Practice stays on the iPhone."),
        .init(id: 1, title: "Move, run, jump", subtitle: "One stick can do more than move.",
              detail: "Stick+ adds actions as you push farther or in different directions. For example, a gentle push walks, a farther push runs, and the edge taps jump. In Edit, hold the stick to choose its actions and thresholds.", illustration: .stick,
              imageDescription: "A stick has inner movement, middle run and outer jump zones. These are examples you can configure."),
        .init(id: 2, title: "Aim and fire together", subtitle: "Touch and drag one control.",
              detail: "Button Aim can hold aim, fire and move the camera with the same touch. A repeating trigger suits tap-fire weapons; a held trigger suits continuous fire. Touch Aim offers optional stages, but needs a comfortable setup your phone can detect.", illustration: .aim,
              imageDescription: "A finger moves an aim-and-fire pad; LT, RT and the right stick work together."),
        .init(id: 3, title: "Steer and accelerate", subtitle: "Combine a trigger with stick movement.",
              detail: "A drive control can press the throttle while you drag left or right to steer. Keep separate brake and steering controls when useful. These combinations are examples: the game decides what each Xbox input does.", illustration: .drive,
              imageDescription: "A drive pad combines left and right steering with the right trigger for acceleration, beside a separate brake button."),
        .init(id: 4, title: "Put controls within reach", subtitle: "Your layout should fit you.",
              detail: "Tap Edit to move controls. Hold one to change its size or behavior, then tap Done and Save. Hold Toggle keeps an action pressed; a second tap releases it. Menus can minimize to movable circles. Center stops sticks; Stop releases all phone actions.", illustration: .layout,
              imageDescription: "Small circular controls move toward the left side of the screen; menu circles can move too."),
        .init(id: 5, title: "Connect to Mac or Windows", subtitle: "No Pico or console adapter is needed.",
              detail: "Run the free receiver on your computer. Mac uses keyboard and mouse, including mapped controller layouts. Windows can also use an Xbox gamepad driver. On the same trusted network, open Bridge → Bridge settings, choose Mac or Windows PC, enter the displayed IPv4 address and port, then Save and connect. Support → PC has the downloads.", illustration: .pc,
              imageDescription: "An iPhone connects by Wi-Fi to a PC running receiver software. Enter the IP address shown by that receiver."),
        .init(id: 6, title: "Connect to a console", subtitle: "A compatible controller and bridge are separate hardware.",
              detail: "The tested Xbox route uses a Raspberry Pi Pico W and an Xbox Adaptive Controller. Open Support → Console for the GitHub connection guides, firmware and Permobil joystick setup. PlayStation needs a separately verified compatible route; the Xbox Pico cannot plug directly into a PS5.", illustration: .console,
              imageDescription: "The phone sends Wi-Fi input to a Pico W bridge, then an adaptive controller, then the console."),
        .init(id: 7, title: "Help is always close", subtitle: "Come back whenever you need it.",
              detail: "Open Tools → Support for this guide, connection instructions, videos and the FAQ. Profiles keep different layouts for different games. Export a backup before trying a big redesign. You can explore every control in Practice first.", illustration: .support,
              imageDescription: "Support offers a quick-start guide, videos, PC and console setup, and a written FAQ.")
    ]
}

struct AppQuickStartView: View {
    let onFinish: () -> Void
    @State private var selection = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var accent: Color { Color(uiColor: ControllerAppearancePalette.accent) }

    var body: some View {
        VStack(spacing: 0) {
            Text("Swipe the pictures or use Next")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal).padding(.top, 8)
            TabView(selection: $selection) {
                ForEach(QuickStartPage.all) { page in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            QuickStartIllustration(kind: page.illustration)
                                .frame(height: dynamicTypeSize.isAccessibilitySize ? 170 : 200)
                                .frame(maxWidth: .infinity)
                                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(page.imageDescription)
                                .accessibilityAddTraits(.isImage)
                            Text(page.title).font(.title2.bold())
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("quickStart.title.\(page.id)")
                            Text(page.subtitle).font(.headline).foregroundStyle(accent)
                            Text(page.detail).font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(20)
                    }
                    .tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityIdentifier("quickStart.pages")
            VStack(spacing: 10) {
                Text("\(selection + 1) of \(QuickStartPage.all.count)")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Page \(selection + 1) of \(QuickStartPage.all.count)")
                    .accessibilityIdentifier("quickStart.progress")
                HStack(spacing: 12) {
                    Button { selection = max(0, selection - 1) } label: {
                        Text("Back").frame(minWidth: 58, minHeight: 44)
                    }
                        .buttonStyle(.bordered).disabled(selection == 0)
                        .accessibilityIdentifier("quickStart.back")
                    Button {
                        if selection == QuickStartPage.all.count - 1 { onFinish() }
                        else { selection += 1 }
                    } label: {
                        Text(selection == QuickStartPage.all.count - 1 ? "Start using the app" : "Next")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("quickStart.next")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .navigationTitle("Quick start")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip") { onFinish() }.accessibilityIdentifier("quickStart.skip")
            }
        }
    }
}

struct ReplayQuickStartView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { AppQuickStartView(onFinish: { dismiss() }) }
}

/// Vector pictures stay sharp at every display size and contain no real game footage.
private struct QuickStartIllustration: View {
    let kind: QuickStartPage.Illustration
    private var accent: Color { Color(uiColor: ControllerAppearancePalette.accent) }
    private var cyan: Color { Color(uiColor: ControllerAppearancePalette.cyan) }
    private var well: Color { Color(uiColor: ControllerAppearancePalette.well) }

    var body: some View {
        Group {
            switch kind {
            case .practice:
                HStack(spacing: 22) {
                    stick
                    VStack(spacing: 16) { round("A"); Label("Stop", systemImage: "stop.fill").font(.headline).foregroundStyle(.red) }
                }
                .overlay(alignment: .top) { Text("PRACTICE").font(.caption.bold()).tracking(2).offset(y: -22) }
            case .stick:
                HStack(spacing: 22) {
                    ZStack {
                        Circle().stroke(cyan.opacity(0.7), lineWidth: 5).frame(width: 116, height: 116)
                        Circle().stroke(accent.opacity(0.6), lineWidth: 4).frame(width: 82, height: 82)
                        Circle().fill(well).frame(width: 48, height: 48)
                        Image(systemName: "arrow.up").font(.title.bold()).foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Move", systemImage: "figure.walk")
                        Label("Run", systemImage: "figure.run")
                        Label("Jump", systemImage: "arrow.up.circle.fill")
                    }.font(.headline)
                }
            case .aim:
                HStack(spacing: 22) {
                    ZStack {
                        Circle().stroke(accent, lineWidth: 3).frame(width: 116, height: 116)
                        Image(systemName: "scope").font(.system(size: 46)).foregroundStyle(accent)
                        Image(systemName: "hand.point.up.left.fill").font(.system(size: 38)).offset(x: 40, y: 40).foregroundStyle(cyan)
                    }
                    VStack(spacing: 10) { pill("LT aim"); pill("RT fire"); pill("RS look") }
                }
            case .drive:
                HStack(spacing: 14) {
                    VStack(spacing: 12) {
                        Image(systemName: "steeringwheel").font(.system(size: 38))
                        HStack { Image(systemName: "arrow.left"); Text("RT throttle").font(.caption.bold()); Image(systemName: "arrow.right") }
                    }
                    .foregroundStyle(accent).padding(18).background(well, in: RoundedRectangle(cornerRadius: 18))
                    round("LT", caption: "Brake")
                }
            case .layout:
                HStack(spacing: 24) {
                    VStack(spacing: 10) { HStack { round("A"); round("B") }; HStack { round("X"); round("Y") } }
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.left.and.right.and.arrow.up.and.down").font(.largeTitle).foregroundStyle(accent)
                        Image(systemName: "slider.horizontal.3").font(.title3).padding(13).background(well, in: Circle())
                    }
                }
            case .pc:
                VStack(spacing: 18) {
                    HStack(spacing: 22) { device("iphone", title: "Phone"); Image(systemName: "wifi").foregroundStyle(accent); device("desktopcomputer", title: "PC receiver") }
                    Text("IP address shown by your receiver").font(.caption).foregroundStyle(.secondary)
                    Text("192.168.1.20  ·  example").font(.caption.monospaced()).padding(8).background(well, in: Capsule())
                }
            case .console:
                VStack(spacing: 18) {
                    HStack(spacing: 12) { device("iphone", title: "Phone"); Image(systemName: "wifi"); device("cpu", title: "Pico W") }
                    HStack(spacing: 12) { Image(systemName: "arrow.down"); device("gamecontroller", title: "Adaptive controller"); Image(systemName: "arrow.right"); device("tv", title: "Xbox") }
                }.foregroundStyle(accent)
            case .support:
                VStack(spacing: 18) {
                    Image(systemName: "lifepreserver.fill").font(.system(size: 50)).foregroundStyle(accent)
                    HStack(spacing: 10) { pill("Guide"); pill("Videos"); pill("FAQ") }
                    Text("Tools → Support").font(.headline)
                }
            }
        }
        .padding(18)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var stick: some View {
        ZStack {
            Circle().fill(well).frame(width: 110, height: 110)
            Circle().stroke(accent.opacity(0.6), lineWidth: 2).frame(width: 108, height: 108)
            Circle().fill(accent).frame(width: 44, height: 44).offset(x: -10, y: -14)
        }
    }
    private func round(_ text: String, caption: String? = nil) -> some View {
        VStack(spacing: 5) {
            Text(text).font(.headline.bold()).foregroundStyle(accent)
                .frame(width: 44, height: 44).background(well, in: Circle())
                .overlay(Circle().stroke(accent.opacity(0.65)))
            if let caption { Text(caption).font(.caption) }
        }
    }
    private func pill(_ text: String) -> some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 7)
            .background(well, in: Capsule())
    }
    private func device(_ symbol: String, title: String) -> some View {
        VStack(spacing: 8) { Image(systemName: symbol).font(.system(size: 30)); Text(title).font(.caption).multilineTextAlignment(.center) }
    }
}
