# LumaForge

Clean-room iOS app for the Wallpaper Engine workflow.

## Stages
1. Fresh LumaForge project and UI foundation.
2. Steam OpenID, Workshop discovery, local package inspection, and MP4 export.
3. Automated simulator build and unit-test gate.

## Platform boundary
Steam's official Workshop installation/download flow is handled by the Steam Client. iOS does not embed that desktop client. LumaForge therefore does not fake a Workshop package download through a web page. It accepts legitimately obtained Workshop files through the iOS Files picker and performs inspection/export locally.

## Build
Xcode 26, iOS 18+, unsigned simulator build in CI.
