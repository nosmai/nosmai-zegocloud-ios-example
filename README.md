# Nosmai Effects with ZEGOCLOUD on iOS

The host publishes Nosmai’s processed camera output as a ZEGO custom video stream. The audience plays that stream in a standard ZEGO canvas.

## Requirements

- Xcode, CocoaPods and two physical iOS devices running iOS 15 or later.
- A Nosmai Effects licence for the broadcaster’s bundle identifier. The Xcode project uses `com.nosmai.quickstart.zegocloud`.
- The Podfile pins `NosmaiCameraSDK 3.0.7` and `ZegoExpressEngine 3.25.0`.

## Set up the project

From the repository root, create the local configuration and install the dependencies.

```sh
cp Configuration/Example.plist Configuration/Local.plist
pod install
open NosmaiZegoDemo.xcworkspace
```

In Xcode, select your signing team for the app target. If you change the bundle identifier, use the same identifier when registering the Nosmai licence. Set these fields in `Configuration/Local.plist`, which Git ignores.

- `nosmaiAPIKey` — App-bound Nosmai Effects licence for the broadcasting device. A viewer can leave this field empty.
- `zegoAppID` — Numeric AppID for a ZEGO project that supports AppSign authentication.
- `zegoAppSign` — Client AppSign for that same project.
- `roomID` — Room ID used by both devices.

This sample uses AppSign authentication. Use your project’s client AppSign for this field. For an application that uses room tokens, retain its existing server-issued token flow when adopting custom capture.

## Broadcast and watch

1. On the first phone, select **Go Live (Host)** and allow camera and microphone access.
2. On the second phone, select **Watch (Audience)** and join the same room.
3. Open the host’s effects controls and apply a visible effect. Check the result on the viewer.
4. Leave the broadcast from the live screen to release the camera and session resources.

## Add Nosmai to an existing app

Reuse your ZEGO engine and room login. Enable custom video capture on the publisher and pass Nosmai output to `sendCustomVideoCapture` with its timestamp. Publish the host stream and play its stream ID on the viewer. Release the frame callback before leaving the room.

- [LiveViewController.swift](NosmaiZegoDemo/LiveViewController.swift) shows capture, publication, remote playback and teardown.
- [EffectsPanelView.swift](NosmaiZegoDemo/EffectsPanelView.swift) applies beauty controls, Cloud Filters and AR effects on the broadcaster.

## References

- [Nosmai iOS quickstart](https://nosmai.com/docs/effects/quickstart/ios/)
- [Register a Nosmai licence](https://nosmai.com/docs/effects/license-key/)
- [ZEGO Express documentation](https://www.zegocloud.com/docs/video-call/overview)
