# Simple Controller for iPhone

Simple Controller turns an iPhone into a customizable, one-finger controller. Create profiles and pages, place buttons and sticks where they are comfortable, and try them in Practice. **Version 0.17.2 (build 24)** was installed and launched on an iPhone 15 Pro.

**[Download the complete iPhone source ZIP](https://github.com/kortorder/simplecontroller-ios/raw/refs/heads/main/SimpleController-iOS-0.17.2-source.zip)** · [SHA-256](https://github.com/kortorder/simplecontroller-ios/blob/main/SHA256SUMS.txt) · [Sample profiles](profiles/README.md)

## Find the controls

- **Bridge menu** connects to the Wi-Fi Pico or returns to Practice. You can see the connection state without scrolling.
- **Camera Follow** turns assisted camera movement on or off in Practice with one tap.
- **All controls** opens a full-height list with camera strength, settings, profiles, pages and status. The entire camera row accepts a tap from the left. The three main actions use full-width rows at accessibility text sizes.

![Controller in portrait](docs/images/controller-portrait.png)

## Build on a Mac

1. Extract the ZIP, or clone this repository. Open `SimpleController.xcodeproj` in Xcode.
2. Select the **SimpleController** scheme and an iPhone simulator, then choose **Run** to use Practice.
3. To use your iPhone, connect it to the Mac. Select the phone as the destination, choose your Apple team under **Signing & Capabilities**, then run. The bundle identifier must be available to the selected team.

The project targets iOS 17 or later and includes its local Swift package. The current build was verified with Xcode 27.2. Run `swift test --package-path Packages/ControllerCore` for package tests and `bash scripts/check.sh` for app-model checks. Builds on a simulator do not need a signing team.

## Xbox and Android

The [Wi-Fi Pico bridge](https://github.com/kortorder/simplecontroller-pico-wifi-bridge) connects the phone to the Xbox Adaptive Controller. The [Omni2 wheelchair joystick bridge](https://github.com/kortorder/omni2-pico-xbox-joystick) is a separate Pico for the chair's Bluetooth joystick. The Pico bridges have been checked with a Mac USB host. Actual Xbox testing is pending. Adjustable trigger pressure requires the optional analog circuit described in the Wi-Fi bridge project.

The [Android project](https://github.com/kortorder/simplecontroller-android) distributes the Android community preview.
