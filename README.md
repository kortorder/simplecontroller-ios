# Simple Controller for iPhone

Simple Controller turns an iPhone into a customizable, one-finger controller. Create profiles and pages, place buttons and sticks where they are comfortable, and try them in Practice. **Version 0.17.2 (build 24)** was installed and launched on an iPhone 15 Pro.

**[Download the complete iPhone source ZIP](https://github.com/kortorder/simplecontroller-ios/raw/refs/heads/main/SimpleController-iOS-0.17.2-source.zip)** · [SHA-256](https://github.com/kortorder/simplecontroller-ios/blob/main/SHA256SUMS.txt)

## Find the controls

- **Bridge menu** connects to the Wi-Fi Pico or returns to Practice. You can see the connection state without scrolling.
- **Camera Follow** turns assisted camera movement on or off in Practice with one tap.
- **All controls** opens a full-height list with camera strength, settings, profiles, pages and status. The entire camera row accepts a tap from the left. The three main actions use full-width rows at accessibility text sizes.

![Controller in portrait](docs/images/controller-portrait.png)

## Build on a Mac

1. Download and extract **SimpleController-iOS-0.17.2-source.zip**. If you cloned this repository, extract the archive of that name from the checkout. In the extracted **SimpleController-iOS** folder, open `SimpleController.xcodeproj` in Xcode.
2. Select the **SimpleController** scheme and an iPhone simulator, then choose **Run** to use Practice.
3. To use your iPhone, connect it to the Mac. Select the phone as the destination, choose your Apple team under **Signing & Capabilities**, then run. The bundle identifier must be available to the selected team.

The project targets iOS 17 or later and includes its local Swift package. The current build was verified with Xcode 27.2. Run `swift test --package-path Packages/ControllerCore` for package tests and `bash scripts/check.sh` for app-model checks. Builds on a simulator do not need a signing team.

## Try an example profile

The complete source ZIP contains `profiles/GTA-6-Prep.json`, `profiles/GTA-V-Left-side.json`, and a guide in `profiles/README.md`. Save the JSON document you want in Files on your iPhone. In Simple Controller choose **All controls → Profiles → Import iPhone profiles** and select the document. Import adds a copy to your library. The GTA 6 Prep sample uses lower-left sticks, repeated A at full forward, and a direct Aim + fire pad. Its game bindings are provisional.

For a complete Git checkout, [download the portable Git bundle](https://github.com/kortorder/simplecontroller-ios/raw/refs/heads/main/SimpleController-iOS-0.17.2.bundle). In the folder where you downloaded it, run `git clone -b source-import SimpleController-iOS-0.17.2.bundle simplecontroller-ios-source`. That checkout already contains the full project.

## Xbox and Android

The [Wi-Fi Pico bridge](https://github.com/kortorder/simplecontroller-pico-wifi-bridge) connects the phone to the Xbox Adaptive Controller. The [Omni2 wheelchair joystick bridge](https://github.com/kortorder/omni2-pico-xbox-joystick) is a separate Pico for the chair's Bluetooth joystick. The Pico bridges have been checked with a Mac USB host. Actual Xbox testing is pending. Adjustable trigger pressure requires the optional analog circuit described in the Wi-Fi bridge project.

The [Android project](https://github.com/kortorder/simplecontroller-android) distributes the Android community preview.
