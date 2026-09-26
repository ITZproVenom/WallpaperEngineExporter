# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-09-26\n\n### Added\n- Public Steam Workshop text search without a bundled Web API key.\n- Automatic Workshop library refresh after authentication.\n- Persistent export history with Files sharing and deletion.\n- Permanent storage for completed MP4 exports.\n\n### Fixed\n- My Wallpapers refresh was previously a no-op.\n- Exported files no longer depend on temporary-directory lifetime.\n\n## [1.0.0] - 2026-09-24

### Added
- Initial public release of Wallpaper Engine Exporter (iOS).
- Steam OpenID authentication via ASWebAuthenticationSession.
- Keychain-backed session storage.
- My Wallpapers grid (Workshop metadata).
- Workshop URL / ID parsing and search.
- Files-based wallpaper import.
- Wallpaper type detection (Video / Scene / Web / Application).
- Full video-wallpaper → MP4 export pipeline (AVFoundation, H.264 / HEVC).
- Export settings (resolution, FPS, duration, codec, quality).
- Progress UI, cancel support, temporary-file cleanup.
- Save to Files / Photos / Share.
- SwiftUI interface with Dark/Light mode and accessibility basics.
- Unit tests for URL parsing, type detection, config, etc.
- GitHub Actions workflow for build & archive.

### Known limitations at v1.0.0
- Scene, Web and Application wallpapers are detected but not rendered/exported.
- Actual Workshop content files must be imported by the user (iOS cannot pull them from a desktop Steam library).
