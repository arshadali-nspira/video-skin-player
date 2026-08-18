# flutter_application_11

A Flutter video player app with a fully custom control surface. Paste a YouTube
link, a bare video ID, or a direct MP4/HLS URL and it plays with hand-built
controls — scrubber with frame previews, timed markers, speed and quality
settings, and a fullscreen mode that works in a portrait-locked app.

The controls live in [`packages/video_skin`](packages/video_skin), a local
package that knows nothing about who is actually playing the video. See its
[README](packages/video_skin/README.md) for the architecture and for how to put
a different playback backend behind it.

## Requirements

| | |
|---|---|
| Flutter | 3.44.2 stable or newer |
| Dart | 3.12.2 or newer (`sdk: ^3.12.2`) |
| Android | Flutter's default `minSdk`; `INTERNET` permission is already declared |
| iOS | Deployment target 13.0, Xcode + CocoaPods |

Verify your toolchain before starting:

```bash
flutter --version
flutter doctor
```

## Setup

```bash
git clone https://github.com/arshadali-nspira/flutter_application_11.git
cd flutter_application_11
flutter pub get
```

`flutter pub get` also resolves the `video_skin` path dependency — you do not
need to run it separately inside `packages/video_skin`.

### About the `flutter_inappwebview` pin

`pubspec.yaml` carries a `dependency_overrides` entry:

```yaml
dependency_overrides:
  flutter_inappwebview: 6.2.0-beta.3
```

This is deliberate. `omni_video_player` pulls in `flutter_inappwebview`, and the
beta is the version that resolves cleanly here. Removing the override will most
likely break `flutter pub get`, so leave it in place unless you are also
upgrading `omni_video_player`.

## Running

```bash
flutter run                 # first connected device
flutter devices             # list what's available
flutter run -d <device_id>  # pick one
```

On iOS the first build runs `pod install` for you, which takes a few minutes.

The app opens on a URL field pre-filled with a sample video, plus a list of
one-tap samples covering YouTube (watch links, `youtu.be`, Shorts), a direct
MP4, and an HLS stream. Anything `classifyVideoInput` cannot parse is rejected
with an inline error rather than a failed navigation.

## Tests

The app and the package have separate suites. Run both:

```bash
flutter test                        # 9 tests — source classification, widgets
cd packages/video_skin && flutter test   # 43 tests — controls, scrubber, fullscreen
```

Static analysis, using the `flutter_lints` rule set in `analysis_options.yaml`:

```bash
flutter analyze
```

## Layout

```
lib/
  main.dart                      app root, portrait lock, FullscreenRotation
  screens/
    home_screen.dart             URL entry and sample list
    player_screen.dart           hosts the player
  player/
    video_source.dart            classifies input into a source
    youtube_link.dart            YouTube URL and ID parsing
    custom_video_player.dart     wires a backend to VideoSkin
    backends/
      omni_playback_adapter.dart VideoPlaybackAdapter over omni_video_player

packages/video_skin/             the backend-agnostic control surface
```

## Notes for contributors

- The app is **locked to portrait**. Fullscreen rotates the widget tree via
  `FullscreenRotation`, not the device — so `FullscreenRotation.builder` must
  stay on `MaterialApp.builder`, above the `Navigator`. The fullscreen layer
  draws into the app's `Overlay`, which a rotation lower in the tree would not
  reach.
- `video_skin` must not import a player package. Backend-specific code belongs
  in a `VideoPlaybackAdapter` subclass under `lib/player/backends/`.
- Build output is ignored via `**/build/`, which covers the nested package
  builds as well as the root.
