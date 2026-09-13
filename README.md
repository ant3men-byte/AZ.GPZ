# AZ.GPS
Stage 1: independent arm64 iOS 12+ host-app library, built with Xcode on GitHub Actions.
Repository name AZ.GPZ is retained; product name is AZ.GPS.

## Included
WolFox-style floating overlay, search/map selection, static GPS simulation, continuous updates, location restore, favorite storage and audit viewer. Other controls are disabled pending separate migration and device validation.

## Build and use
Open Actions → Build AZ.GPS → Run workflow. Download AZ.GPS-arm64-ios12 and extract AZ.GPS.dylib. Embed/load the library in your own experimental application and re-sign the entire application with your signing tool. The ad-hoc build signature is not the final application signature.

No iPhone/device validation or successful Actions build is claimed for this source delivery. Source is based on WolFoxa commit 1f466bdd15591932811d43c0b9a758ae8777eaab. Original repositories are untouched. Do not include the old library alongside this one.

## Device acceptance
Compare disabled behavior against the original app. Test enable/change/restore while updating; requestLocation; stopUpdatingLocation; delegate replacement; foreground/background; normal touches outside the overlay; loading/signing on iOS 12+. Confirm received coordinates rather than treating audit SUCCESS as proof.

## Next stages
Extract runtime/services into smaller modules; migrate MapKit routes, random movement and foreground scheduler from the reviewed dylib-analyzer source with cancellation and mode-transition fixes. Preserve one state owner and one hook layer. Camera/identity/BLE remain deferred.

## Scope
Simulation affects only the process loading this library. Permissions, signing, location authorization and host-app lifecycle still apply.

Compatibility target: iOS 12+ on arm64. This is a deployment target, not confirmed support for every iOS release. Build and device validation remain required.
