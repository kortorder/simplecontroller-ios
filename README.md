# Simple Controller for iPhone

**Install on iPhone:** [Get Simple Controller on the App Store](https://apps.apple.com/us/app/simple-controller/id6834564165).

**Start here:** [Connection FAQ](FAQ.txt) · [Beginner videos](videos/README.md) · [Windows PC receiver download](PC-Receiver.zip).

**Developer downloads:** [Version 1.0.3 (41) source ZIP](SimpleController-iOS-1.0.3-41-source.zip) · [Git bundle](SimpleController-iOS-1.0.3-41-source.bundle) · [SHA-256 checksums](SOURCE-SHA256SUMS.txt).

Simple Controller turns an iPhone into a customizable, one-finger controller. Create profiles and pages, place buttons and sticks where they are comfortable, and try them in Practice. The app supports an optional Cronus Zen USB pressure mode, retains USB full-press LT/RT output and keeps your bridge connection enabled across pages, profiles and settings, and reconnects automatically when you reopen the app. Macro Mode and adjustable automatic release remain available. On first launch, swipe through the eight-page picture guide, then choose Shooter, Racing, Sports or Open World. Existing installations keep their profiles and can replay the guide through Support. To try another layout, tap **Profiles → Game starters** and choose a category. Each choice opens an editable personal copy.

Shooter includes independent Aim and Fire and a combined pad. Racing lets one finger steer while pressing the throttle or brake. Sports offers movement, short and long passes, shooting and sprint. Open World has On foot and Drive pages. Every starter includes a Menus page with the Xbox D-pad, A, B, Menu and View. Button assignments depend on the game. Page changes release old actions and prepare the bridge automatically; no Connect tap is needed.

## Controller options

- **Auto-center while playing:** tap **Edit → Add → Auto-center toggle**, place the small circular button, then Save. Tap it during play to switch all sticks and stick-style Button Aim controls between centering on lift and staying in position. Its ON / OFF / MIXED indicator shows the current state. Turning centering on clears movement left behind by a released touch; an active touch continues normally. The choice lasts across pages and Stop, until you select or reload a profile. It does not overwrite the profile's saved Auto-center settings. **Center** stops retained movement without changing that choice.
- The same local action is available in Stick+ stage settings. `AUTO_CENTER_TOGGLE`, `AUTO_CENTER_ON` and `AUTO_CENTER_OFF` must each be used alone. Entering an edge stage toggles once; pull inward before trying it again. For one-shot Xbox actions such as `X360A(U100)`, enable **Deliberate edge reactivation** to require a small inward move before another press. This avoids repeated edge taps from slight finger movement.
- A repeating aim-and-fire pad can use `LT:0.5,RT:0.7(R100)(U50)` with Button Aim set to the right stick: aim stays held while RT presses for 50 milliseconds every 100 milliseconds. `LT:0.5,RT:0.7` holds both triggers steadily instead. With Hold Toggle off, lifting releases either pad. Actual firing speed depends on the game and weapon; USB full-press trigger mode sends each positive pressure as a full press.
- **Macro Mode** completes a button's sequence after a quick tap. Open Edit, hold the button to open its settings, enable Macro Mode under Button behavior, then tap Done and Save layout. Commands without an explicit duration press for **200 milliseconds**. Each run starts once. Further taps during a run are ignored, and holding the finger down lets that run finish. Release all and interruptions cancel it.
- **Automatic release** uses `(U100)` to press an action for 100 milliseconds after it starts. For example, `X360A(U100),X360A(D500)(U100),X360B(D800)(U100)` with Macro Mode taps A, A again at 500 milliseconds, then B at 800 milliseconds. D delays count from activation, so matching delays start together. Give repeated presses of the same button a gap between their held periods. Ordinary controls can also use U, with normal early release on lift.
- Commands can run immediately, on release, after a delay, with repeat, or with a release delay. For example, `LT:0.5(HRD200)` keeps a half-pressed left trigger for 200 milliseconds after lift. Touch Aim tracks held stages as your fingertip lifts.
- Each manual Touch Aim stage can have its own aiming sensitivity and entry confirmation time. Sensor actions still require local setup.
- Floating rings can use compact boost bands, separate movement and aiming actions and distances, direct fine aim, and an optional delay bypass for a direct Boost 2 touch. Finish can require a direct tap.
- Existing saved layouts keep their settings. Profiles now support up to **128 controls**. New native backups use format 24 and require version 1.0.3 or later; earlier backups still import. Edited Android export reports unsupported new options instead of silently discarding them; an imported Android original remains available unchanged.

## Find the controls

The controller uses the full screen in version **1.0.3 (build 41)**. In Edit, drag a control to any edge; its frame stays inside the screen. Existing profiles retain their saved positions and settings, with normalized positions adapting to the larger surface. The iPhone's physical cutout and rounded corners still limit visible pixels.

The compact menu stays at the top while it is open. Tap **Hide** to replace it with a small, circular **Open menu** button showing three horizontal lines. Drag that 44-point circle to a comfortable place; tap it to reopen the menu at the top. Dragging the circle does not open the menu.

The compact actions toolbar starts near the bottom. Drag its **four-way-arrow handle** to place it elsewhere and free the bottom area for game controls. Its small, circular buttons are **Edit**, **Center** and **Stop** during play, or **Cancel**, **Add** and **Save** while editing. Center re-centers the sticks; Stop releases all phone inputs while keeping the bridge connection enabled.

Tap the actions toolbar's **minus button** to hide it. A separate, draggable 44-point circle with a sliders icon appears; tap that **Open actions menu** circle to bring the toolbar back. The top menu and actions toolbar can be hidden independently, and the app remembers both choices.

Tap the actions toolbar's **…** button to open **Toolbar position**:

- Turn **Vertical toolbar** on to stack its buttons in a narrow column, or off to put them in a row. This choice is saved and applies in both portrait and landscape. Tap **Done** to return to the controller.
- Choose **Top**, **Bottom**, **Left** or **Right** to move it to a screen edge, or use its arrow handle for a position in between.
- **Reset position** restores the actions toolbar's default position in the current orientation. **Reset all toolbars** restores positions in both orientations, including both minimized menu circles. It keeps the horizontal or vertical choice and whether each menu is hidden.

Toolbar and menu-circle positions are remembered separately for portrait and landscape. These settings are separate from profiles: moving a toolbar or changing its shape does not move game controls, change payloads, or require Save. Toolbar moves release current actions without disconnecting the bridge. An overflow arrow marks action-toolbar content that can scroll when space is limited.

The top menu provides these shortcuts:

- **Bridge** opens connection choices and settings. Its status is visible without scrolling.
- **Profiles** selects a controller profile; **Page** switches pages within it.
- **Camera** turns Camera Follow on or off in Practice or Windows PC mode. Camera strength is in Tools.
- **Tools** opens **All controls**, a full-height list with settings, camera strength, profiles, pages, Support and status.
- **Support** is available in Bridge and All controls. Its **Learn / PC / Console** tabs include the picture guide, free Windows receiver instructions and links to the console bridge projects.

## Connect to a Windows PC without extra hardware

Download **PC-Receiver.zip** from [Releases](https://github.com/kortorder/simplecontroller-ios/releases). Follow its [setup guide](receiver/README.md) on your Intel/AMD 64-bit Windows gaming PC, then open **Bridge → Bridge settings → Windows PC • free receiver** on the phone. Enter the PC's local IPv4 address and port **42734**. Save and connect. Keep the receiver open while playing.

The receiver and its Python packages are free. Its free virtual Xbox-controller driver, ViGEmBus, is archived/end-of-life; install the official final release linked in the receiver guide and review its prompts yourself. No Pico or adaptive controller is required for PC play. The receiver is required software: an unprepared PC cannot receive controls automatically. Mac and Windows ARM game output are not supported by this package.

This mode supports gamepad controls with adjustable triggers, keyboard and mouse commands, touchpad movement/scrolling and Camera Follow. Xbox Guide/logo and Share remain unavailable through this PC route. A new connection starts neutral; a lost link clears phone input after a 500 ms receiver lease. Other independent assistive input owners keep their own inputs. This route has automated protocol, model and simulator checks; physical Windows driver/game acceptance remains to be tested.

## Beginner help and videos

- [Connection and beginner FAQ](FAQ.txt): Pico model, Xbox setup, PC setup and qualified PlayStation guidance.
- [Instructional videos and downloads](https://github.com/kortorder/simplecontroller-ios/releases): silent 30-second preview, 3-minute-30-second beginner guide and companion instructions. The tutorial shows the iPhone interface; the Android app has its own illustrated guide and some features differ.
- On first installation, the offline illustrated guide covers comfortable controls, Stick+, aim/fire, drive/steer, holds/macros, profiles, PC IP setup and console support. Skip, resume or replay it at any time. It does not replace existing profiles.

## Build on a Mac

1. Extract the ZIP, or clone this repository. Open `SimpleController.xcodeproj` in Xcode.
2. Select the **SimpleController** scheme and an iPhone simulator, then choose **Run** to use Practice.
3. To use your iPhone, connect it to the Mac. Select the phone as the destination, choose your Apple team under **Signing & Capabilities**, then run. The bundle identifier must be available to the selected team.

The project targets iOS 17 or later and includes its local Swift package. The current build was verified with Xcode 27.2. Run `swift test --package-path Packages/ControllerCore` for package tests and `bash scripts/check.sh` for app-model checks. Builds on a simulator do not need a signing team.

## Xbox and Android

The [Wi-Fi Pico bridge](https://github.com/kortorder/simplecontroller-pico-wifi-bridge) connects the phone to the Xbox Adaptive Controller. The [Omni2 wheelchair joystick bridge](https://github.com/kortorder/omni2-pico-xbox-joystick) is a separate Pico for the chair's Bluetooth joystick. The existing phone buttons, sticks and wheelchair joystick have been checked on Xbox. The user also confirmed USB LT/RT press/release, simultaneous chair right-stick input and page switching without manual reconnect in Xbox Accessories. Adjustable pressure can use the analog-circuit firmware, or the new experimental XInput firmware through Cronus Zen. The Zen route has passed software checks and cross-builds; its actual Xbox connection and combination with the chair still require physical verification.

The [Android project](https://github.com/kortorder/simplecontroller-android) distributes the Android community preview.

## Staying connected

After you save valid bridge settings or connect a bridge, opening or returning to the app connects to that saved bridge automatically, unless you have explicitly selected Practice. The previous five-minute cutoff no longer applies. Every new connection starts with released controls and waits for the bridge's neutral confirmation; old holds, repeating buttons and macros never resume on their own. Connection attempts run only while the app is active.

Changing pages or profiles, opening settings, editing, and Stop / Release all keep the connection enabled. Old actions are cleared immediately; a fresh neutral handshake briefly pauses controls before you can touch them again. If Wi-Fi or the bridge is unavailable, controls remain released while the open app retries automatically.

**Disconnect** stops the current connection and retries for this visit. The next time you leave the app and open it again, the saved bridge can reconnect. A temporary permission prompt or notification does not undo Disconnect. Choose **Practice on this iPhone** to keep using Practice across app openings; it stays selected until you choose the bridge again.

For a new bridge, enter its address and port in Bridge settings and use **Save and connect**. If you save a new valid address while the bridge is offline, the next opening retries that new address. Unsaved form edits are not used. An invalid saved address or port blocks automatic reopening until corrected. Connection preferences are stored separately from profiles and never change saved layouts.

## USB full-press triggers (0.22)

In Bridge settings, LT and RT output offers Off, USB buttons (full press), Adjustable (circuit), and USB adjustable (Cronus Zen). Existing installations keep their previous choice. USB buttons requires the updated phone Pico firmware; use a separate Xbox Accessories controller profile that maps X1 to LT and X2 to RT, then select that profile slot. Existing switches or USB buttons assigned to X1/X2 follow those mappings too.

With USB buttons selected, any positive LT/RT payload becomes a full press and zero releases it. Saved actions, pressure amounts, layouts, Macro Mode timing and the adjustable circuit option remain unchanged. In Practice the original pressure amounts still display. Unsupported firmware never silently falls back to a different trigger mode. Page/profile changes and Release all retain the connection through neutral confirmation; reopening the app reconnects automatically, always without old held inputs.

When the chair Pico occupies the XAC right USB port, the chair controls the right stick. The phone can supply LT, RT and left-stick movement alongside it. With ordinary independent firmware, phone right-stick output is ignored by the XAC while the chair supplies that stick; this does not prevent phone trigger input. The optional shared-right-stick firmware for both Picos relays the phone stick to the chair Pico over Wi-Fi. Nonzero phone input takes priority, then centering hands control back to the chair. Its Mac USB/live-phone checks passed; complete combined Xbox acceptance remains a separate hardware check. See the two bridge repositories for the matching setup. Validate actual Xbox button mappings and releases before gameplay.

## Cronus Zen USB pressure (0.23 candidate)

Choose **USB adjustable (Cronus Zen)** only with the matching phone Pico XInput firmware. It preserves the existing LT/RT values, layouts, macros and page connection behavior. The existing XAC output choices and source are retained. The firmware choices are separate images; changing the app setting does not reflash the Pico.

The intended connection is phone → Wi-Fi Pico → Zen A3 → Xbox, with a genuine Xbox controller in Zen A1. Keep the chair Pico in the XAC right USB port and connect the XAC separately to Xbox; use Xbox Controller Assist to combine them. The external-right-stick firmware option keeps the phone's RX/RY neutral so the chair owns the camera. The phone-right-stick option remains available for other setups.

This candidate is software-tested, not yet physically proven with Zen or Controller Assist. Retain the known-working XAC firmware for return to the current setup. Chair nudge buttons can be set to Off through the existing maintenance settings without replacing chair firmware or erasing Bluetooth pairing. See [firmware and physical test details](docs/CRONUS_ZEN.md).

## PlayStation

The XAC Pico firmware is not a direct PS5 or Sony Access controller accessory. The experimental Zen/XInput source and vendor-specific adapter guidance are documented in [FAQ.txt](FAQ.txt); this project has not verified a complete physical PlayStation connection. Check the exact route before buying hardware. Existing Xbox Adaptive Controller connection options remain supported.
