# LumaForge

LumaForge is a clean-room iOS Wallpaper Engine workshop browser and exporter.

## What it does
- Steam OpenID sign-in with Keychain-backed identity
- Wallpaper Engine Workshop discovery and search
- Workshop item detail and preview
- Local import of Workshop packages and media through the iOS Files picker
- Automatic inspection of project.json / scene.json
- PKG signature extraction for embedded PNG/JPEG/MP4/WebM assets
- Image export to PNG and video export to MP4
- Persistent export history with Share Sheet
- Liquid Glass UI on modern iOS, with graceful fallback
- No Steam credentials are stored by the app

## Important platform boundary
Steam's official Workshop download/install path is executed by the Steam Client. iOS cannot embed the desktop Steam Client. LumaForge therefore never pretends that a web page is a Workshop package downloader. It imports the user's legitimately obtained Workshop files through Files, then performs the actual extraction/export locally.

## Build
Open `LumaForge.xcodeproj` in Xcode 26 or newer and run the `LumaForge` scheme on iOS 18 or newer.

CI builds the unsigned iOS application and runs the unit tests.

## Build status
The repository is intentionally rebuilt as a new LumaForge project rather than layered over the previous implementation.

CI validation branch.
