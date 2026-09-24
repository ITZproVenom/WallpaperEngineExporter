# Wallpaper Engine Exporter

**iOS-only** app that lets you access Wallpaper Engine (Steam AppID 431960) Workshop metadata for your authenticated account and export supported wallpapers as MP4 video files.

## What it does

1. **Sign in with Steam** – Real Steam OpenID / web authentication flow (no password entry in the app).
2. **My Wallpapers** – View subscribed / available Wallpaper Engine Workshop items (metadata).
3. **Import** – Import legitimately obtained Wallpaper Engine project files or archives via the system Files picker.
4. **Export to MP4** – Fully supported path for **video wallpapers**. Other types are detected and reported with clear limitations.

## Important iOS limitations (technical honesty)

- iOS cannot access a desktop Steam installation path such as `steamapps/workshop/content/431960`.
- Steam Workshop **file downloads** of the actual wallpaper packages are not freely available to third-party iOS apps the same way the desktop client obtains them. The app therefore relies on:
  - Workshop **metadata** (title, author, preview, type hints) via authenticated Steam endpoints where possible.
  - **User-provided import** of the wallpaper files you already own (via Files).
- **Scene wallpapers**, **Web wallpapers**, and **Application wallpapers** use proprietary or desktop-only runtimes. Full faithful rendering on iOS is not currently implemented. The app detects these types and explains the limitation instead of faking a renderer.
- Only **video wallpapers** that contain a real video file receive a complete export pipeline (preview, trim, loop, encode to H.264/HEVC MP4).

## Supported wallpaper types

| Type            | Detection | Preview | Export to MP4 |
|-----------------|-----------|---------|---------------|
| Video           | Yes       | Yes     | Yes (full)    |
| Scene           | Yes       | Limited | Not supported |
| Web             | Yes       | Limited | Not supported |
| Application     | Yes       | No      | Not supported |

## Requirements

- iOS 17+
- Xcode 15+ (for building)
- Apple Developer account (for device installation / App Store / Ad-Hoc / TestFlight)
- Steam account that owns Wallpaper Engine

## Steam Login

Uses a legitimate Steam-compatible web authentication flow (`ASWebAuthenticationSession` + Steam OpenID).  
Session data is stored in the iOS Keychain. No Steam passwords are ever requested or stored by the app.

## Building

```bash
# Clone
git clone https://github.com/ITZproVenom/WallpaperEngineExporter.git
cd WallpaperEngineExporter

# Open in Xcode
open WallpaperEngineExporter.xcodeproj
```

Or use the GitHub Actions workflow (see `.github/workflows/build-ipa.yml`).  
**Note**: Producing a signed IPA that installs on devices requires your own Apple Developer certificates and provisioning profiles stored as GitHub secrets. The CI workflow builds the project and produces an archive; full signed IPA distribution still needs those secrets.

## Distribution

Releases (including any available IPA) are published on the [GitHub Releases](https://github.com/ITZproVenom/WallpaperEngineExporter/releases) page.

## Known limitations

- No direct download of Workshop content packages from Steam to iOS.
- Scene / Web / Application wallpapers cannot be fully rendered or exported on iOS.
- Large video exports are memory- and storage-intensive; the app streams frames where possible and cleans up temporary files.
- Steam Web API rate limits and authentication requirements apply.

## License

MIT – see LICENSE.
