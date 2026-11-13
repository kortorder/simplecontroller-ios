# Simple Controller Privacy Policy

Updated November 13, 2026. Published by the Simple Controller project.

Simple Controller lets you create and use touch controller profiles on your iPhone. Practice works on your device. Bridge mode sends controller commands to the bridge address you configure. No account is required.

## Data stored and used on your device

The app saves your profiles, control layouts, reusable settings, calibration summaries, display preferences, bridge address and port, protocol settings, and recovery copies in its local app storage. It also saves a short-lived connection-resume record so it can decide whether to resume a connection after a brief interruption. These records support the app’s features; they are not sent to a developer-operated service.

Touch positions, timing, contact-size measurements, and force measurements where your device supports them are processed to operate controls and calibrate touch behavior. Raw calibration samples remain in the calibration view’s memory and are discarded when it closes. Calibration summaries you choose to apply or save become part of your saved settings and profiles. The app does not use these measurements to identify you.

The app does not access your camera, microphone, location, contacts, or photo library. The Camera Follow feature refers to simulated game-camera behavior, not your iPhone camera.

## Imports and exports

You choose which files to import through the system file picker. Native backups are processed locally into profiles and settings. Imported Android profiles also preserve a copy of the original file, its display name, and verification metadata in the app’s local storage, so you can recover or export the original later. The preserved original can include fields that the iPhone app does not use, including any information already present in the file.

Exports happen when you choose to export and select a destination. Export all profiles includes your current profile library and available preserved Android originals. Separate commands can export an unchanged Android original, a reviewed edited Android copy, or a recovery document. Normal profile backups do not include the app’s bridge connection settings or currently held input. An imported original is preserved as supplied, so its contents are not limited by that statement.

If you select iCloud Drive, another file provider, or a sharing destination, that service or recipient receives the file you selected. Its handling of that file is governed by its own policies and your settings. Simple Controller does not automatically send these exports to its developer.

## Controller connections

When you connect a bridge, the app sends controller state, connection/session tokens, sequence numbers, and protocol messages to the configured IPv4 address and port, normally a bridge on your local network. Controller state includes supported buttons, sticks, directional-pad input, and trigger values. The bridge replies with readiness and acknowledgment messages. This exchange operates the controller; it does not upload your profile library or imported originals to a developer service.

The connection uses UDP and has no app-level encryption or authentication. Session tokens keep connection sessions separate; they are not an account or device identifier. The network and receiving bridge can see the packets and network addresses needed for the connection. Disconnecting or switching to Practice stops the controller connection. You can also revoke Local Network access in iOS Settings.

A bridge and its hardware or firmware may have their own data-handling behavior. This policy describes the iPhone app.

## Developer collection, advertising, and analytics

This version has no developer-operated data-collection endpoint, advertising SDK, analytics SDK, automatic crash-reporting SDK, or tracking function. The developer does not receive your locally stored profiles, touch measurements, or controller packets through the app. Apple may process App Store, device diagnostic, or backup information under Apple’s own settings and policies.

## External links and optional support

Help and privacy links open GitHub in your browser only when you choose them. GitHub receives the browser and network information needed to serve those pages and handles it under its own privacy policy.

If you choose to submit a GitHub issue, the information you post is public and can be read by the project’s maintainers and other visitors. Do not post private files, personal information, or network addresses. The app does not automatically attach profiles, diagnostics, or other app data. Information you submit is retained by GitHub under its policies and account controls; removing app data does not remove a public issue or copies others may have made.

## Retention and deletion

Profiles and settings remain in the app’s local storage until changed or the app’s stored data is removed. Deleting a profile removes it from the active profile list but deliberately keeps a local recovery copy. Resetting or restoring profiles may also preserve recovery copies. Preserved Android originals are stored separately and are not erased by deleting their converted profiles. The current version does not provide an in-app command to erase every recovery copy and original.

Deleting the app through iOS removes its app-managed local data. Offloading the app preserves its documents and data. Exported files, copies you shared, and device backups are separate copies and must be managed where you saved or shared them. Your iCloud or computer device backups may include app data according to your device settings; Simple Controller does not provide its own cloud-sync or backup service. Restoring a backup can restore previously saved app data.

## Questions and policy changes

For privacy questions, use the Simple Controller support issues link below. Keep your question free of private information because issues are public. Please do not send a profile or original file unless you want its contents shared with the recipient. This policy will be updated if the app’s data practices change.

[Privacy questions and support](https://github.com/kortorder/simplecontroller-ios/issues) · [GitHub privacy policy](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
