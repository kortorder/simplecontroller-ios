# Simple Controller support

Open **Bridge → Support** or **Tools → All controls → Support** in the app. Learn, PC and Console tabs explain the basics and connection options. Replay the illustrated quick start whenever needed.

- [Connection and beginner FAQ](../FAQ.txt) — PC, exact Pico model, Xbox setup and PlayStation limitations.
- [Free Windows receiver setup](../receiver/README.md) — install receiver software/driver, enter the PC’s local IP address and port 42734, and test controls. No extra bridge hardware is needed for PC use.
- [Videos and downloads](https://github.com/kortorder/simplecontroller-ios/releases) — silent 30-second preview, 3:30 beginner guide, companion chapter guide and receiver ZIP.
- [Wi-Fi Pico bridge](https://github.com/kortorder/simplecontroller-pico-wifi-bridge) — phone to Xbox Adaptive Controller.
- [Permobil Omni2 joystick bridge](https://github.com/kortorder/omni2-pico-xbox-joystick) — separate chair Pico.
- [Android community app](https://github.com/kortorder/simplecontroller-android).

Xbox setup needs a correctly configured RP2040 Pico W/WH and compatible Adaptive Controller power/cables. Ordinary USB LT/RT mode is full press/release. Adjustable pressure needs the matching additional route. PlayStation/Zen/Pico combinations remain experimental; a Pico does not plug directly into Sony Access as a USB accessory.

The Windows receiver is free and targets Intel/AMD 64-bit Windows. Its free ViGEmBus virtual controller driver is archived; see the official final release and notices in the setup guide. New iPhone PC transport has automated/simulator tests; physical Windows driver and game acceptance still needs a Windows test.

## Keep your layout safe

Export a profile backup before experimenting. Updates preserve profiles and saved positions. The illustrated guide does not replace existing layouts. Stop / Release all clears phone actions. Use explicit Disconnect or Practice when you do not want game output.

## Report a problem

Use [GitHub Issues](https://github.com/kortorder/simplecontroller-ios/issues). Include app version, phone/OS, output mode, the step that failed and what you expected. Do not post Wi-Fi passwords, private firmware, Bluetooth pairing backups or personal account information. Diagnostic exports can contain commands/network addresses; review before sharing.

[Privacy policy](PRIVACY.md). No app account is required; profiles and guide progress are stored on your device.
