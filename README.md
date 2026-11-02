<div align="center">

<div alt style="text-align: center; transform: scale(.25);">
	<picture>
		<img alt="Immi Logo" src="assets/immi-logo.svg" width="170" style="width: 170px;" />
	</picture>
</div>

# Immi
![GitHub License](https://www.shieldcn.dev/github/license/varunaditya-plus/Immi.svg?variant=outline&size=sm)
[![GitHub Downloads (all assets, all releases)](https://shieldcn.dev/github/downloads/varunaditya-plus/Immi.svg?variant=outline&size=sm)](https://github.com/varunaditya-plus/Immi/releases/latest)
[![GitHub Release](https://shieldcn.dev/github/release/varunaditya-plus/Immi.svg?size=sm)](https://github.com/varunaditya-plus/Immi/releases/latest)
![Please star this repo](https://shieldcn.dev/badge/★%20please%20star-22c55e.svg?theme=amber&color=eab308&size=sm&variant=outline)

Immi is a native iOS app for Immich that looks and works like Apple's Photos app, made for users who want the clean,</br>familiar Photos experience they already understand, while being able to back up their photo library to Immich.

</div>

---

## Features
**Library and Collections**
- Browse your library by Years, Months, or All Photos, and pinch to change the grid size.
- Sort by capture date or recently added, and filter favorites, edited photos, videos, screenshots, and photos not in an album.
- Customize Collections with pinned items, rearrangeable sections, and different card sizes.
- Browse Recent Days, Memories, Featured Photos, favorites, archived photos, and Recently Deleted.

**Albums, People, and Maps**
- Create and edit albums, choose key photos, and add or remove photos.
- Organize albums into folders and set custom photo ordering on this device.
- Name, favorite, hide, and merge people recognized by Immich, or organize them into groups on this device.
- Explore geotagged photos on a map, switch to satellite view, and browse photos near a selected place.

**Search**
- Search your Immich library by text, with suggestions for people, places, and dates.
- Refine results by people, location, date range, media type, or album.
- Revisit recent searches and recently viewed photos.

**Viewing and Editing**
- View photo information, edit captions, and adjust dates and locations.
- Crop, straighten, rotate, and flip photos, with tonal adjustments, filters, undo, and redo.
- Trim videos, change playback speed, and mute audio.
- Choose a Live Photo key frame, turn Live off, or apply Loop, Bounce, and Long Exposure effects.
- Keep edits reversible on this device, preserving the original files on Immich.

**Sharing and Backup**
- Share photos and videos with format options and control over included location data.
- Create shared links and manage shared albums.
- Upload through the iOS share sheet or the Photos upload action.
- Back up selected device albums, including Live Photos, with separate cellular-data settings for photos and videos.
- Monitor backup progress, review duplicates reported by Immich, and free up verified device copies.

**Widgets and Accessibility**
- Display albums and Memories in Home Screen widgets.
- Use a simplified interface in Apple's Assistive Access.
- Browse cached library and collection information during temporary connection failures.
- Use light or dark mode on iPhone and iPad.

## Requirements
- **iPhone or iPad** running iOS / iPadOS 26 or later.
- **Immich server** running v2 or v3 that your device can reach. Use HTTPS if the server is accessible from outside your home network.
- **Xcode 26.5 or later** on a Mac to build and install the app, with an Apple account for device signing.

## Setup
1. Clone this repository and open `ImmichApp.xcodeproj` in Xcode.
2. Select the **Immi** scheme.
3. In **Signing & Capabilities**, select your development team for the app and all extensions. If you use a different team or bundle identifiers, align the shared App Group and Keychain groups across target entitlements and source configuration, including `SharedUpload/SharedSession.swift`; its `keychainAccessGroup` must use your signing prefix.
4. Choose your iPhone or iPad, then build and run.
5. Enter your Immich server URL and sign in with email and password or your server's OAuth/OIDC provider.
6. To enable backup, grant photo-library access and select the device albums you want to upload.

No third-party package installation is required. Search, face recognition, Memories, and duplicate groups depend on the features and information available from your Immich server. Visual search within an album requires a stable Immich Server v3.2 or later.

Immi connects directly to your chosen server. It is an independent project and is not affiliated with or endorsed by Apple or the Immich team.

## Development
Run the tests in Xcode with **Product → Test**, or from the command line with any installed simulator:

```sh
xcodebuild test \
  -project ImmichApp.xcodeproj \
  -scheme Immi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Replace the simulator name with one installed on your Mac. The tests cover authentication and account isolation, Immich API contracts, backup and storage recovery, library organization, search, sharing, editing, media playback, privacy, and UI layout. Native UI tests use a local mock Immich server to exercise album and duplicate actions.

<details>
<summary>Project layout</summary>

```text
ImmichApp/                   Main SwiftUI application
  App/                       App lifecycle, navigation, and appearance
  Components/                Shared interface components
  Core/                      Authentication, networking, storage, Photos access, and widgets
  Features/                  Library, Collections, albums, people, maps, search, editing, and backup
  Models/                    Domain models and Immich API data models
  Resources/                 Assets, app configuration, and localization
ImmichApp.xcodeproj/          Xcode project and shared schemes
ImmichWidgets/               Home Screen widgets
ImmiShareExtension/           iOS share-sheet extension
ImmiUploadAction/             Photos upload action extension
SharedUpload/                Upload code shared by the extensions and app
Tests/                       Unit, contract, lifecycle, and hosted interface tests
UITests/                     Native interface tests and local mock Immich server
assets/                      README logo
```

</details>

## Contributing
If you have suggestions, features, or bug reports you want implemented, please open an issue. If you can code, please try to fix the issue you found and open a pull request. Please include any details in your issue that may be relevant (screen recording, screenshots, etc.)

If you have a bug report, please include your Immi version, iOS version, Immich server version, and steps to reproduce your issue.

## Credits
- [SelfPhotos](https://github.com/rendiwijiatmoko/iOS-SelfPhotos) by [rendiwijiatmoko](https://github.com/rendiwijiatmoko) acted as the base for it.
- [Immich](https://github.com/immich-app/immich) and its community inspired this project.
