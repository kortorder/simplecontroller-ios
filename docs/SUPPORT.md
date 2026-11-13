# Simple Controller support

Simple Controller is a customizable iPhone touch controller. Arrange buttons, sticks and touch controls around your reach, and try them in Practice before connecting hardware.

## Start in Practice

Open **Bridge menu → Practice on this iPhone**. No extra hardware is needed. Use **Profiles → Game starters** for an editable example. Tap **Edit**, move a control, or press and hold it to change its settings. **Save layout** keeps the changes; **Cancel** restores the saved layout. **Release all** clears held inputs, repeats and delayed actions.

## Connect to Xbox

The tested route uses a Raspberry Pi Pico W with the project's compatible Wi-Fi bridge firmware and an Xbox Adaptive Controller. The phone and Pico use the same trusted network. Open **Bridge menu → Bridge settings**, enter the Pico's address and port, and connect. Allow Local Network access when iOS asks.

- [Wi-Fi Pico firmware and setup](https://github.com/kortorder/simplecontroller-pico-wifi-bridge)
- [Separate Omni2 chair-joystick Pico](https://github.com/kortorder/omni2-pico-xbox-joystick)

USB-button trigger mode provides full LT/RT presses through X1/X2 mappings in Xbox Accessories. Adjustable trigger pressure requires a different compatible hardware route. The Cronus Zen route remains experimental and needs its physical Xbox verification. Changing an app setting does not install firmware or add the required circuit. Keyboard, mouse, Camera Follow and other outputs marked Practice-only are not console output.

## Keep a backup

Open **Profiles → Export all profiles** and choose a file destination you control. Backups include available preserved Android originals. Deleting a profile can leave local recovery copies; see the [privacy policy](PRIVACY.md) for retention and deletion details.

## Get help

[Open a support issue](https://github.com/kortorder/simplecontroller-ios/issues) with your app version, iPhone/iOS version, which bridge mode you use, the steps you tried and the exact message shown. GitHub issues are public: omit passwords, private files, personal details and network addresses. The app does not automatically attach your profiles or diagnostics.

If a Mac-installed development copy stops opening after several days, its Apple signing permission may have expired. Re-signing is temporary. The project is preparing App Store distribution to remove that recurring development-signing expiry; an approved App Store release is not yet available.
