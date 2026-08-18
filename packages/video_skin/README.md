# video_skin

A complete custom control surface for Flutter video, with no opinion about who
is playing the video.

`VideoSkin` draws the controls, the scrubber and its frame previews, the timed
marker overlays, the gestures and fullscreen. A `VideoPlaybackAdapter` connects
all of that to a real player. Nothing in this package imports a player package,
so putting it on top of a second backend — TPStreams, `video_player`, an HLS
SDK, a WebView — is one subclass and no changes here.

```
┌─────────────────────────── VideoSkin ───────────────────────────┐
│  PlayerControls · VideoProgressBar · ScrubPreview               │
│  MarkerOverlay  · FullscreenRotation · fullscreen page          │
└──────────────────────────────┬──────────────────────────────────┘
                               │ reads state, issues commands
                    ┌──────────┴───────────┐
                    │ VideoPlaybackAdapter │  ← the only thing you write
                    └──────────┬───────────┘
              ┌────────────────┼────────────────┐
     OmniPlaybackAdapter  TPStreamsAdapter  VideoPlayerAdapter
```

## What you get

| | |
|---|---|
| Controls | play/pause/replay, ±10s, mute, title, back, settings |
| Progress | scrubbable bar with buffered range, marker ticks, thumb |
| Scrub preview | still frames pulled from the stream, above the thumb |
| Gestures | tap to show/hide, double-tap to seek, swipe up/down for fullscreen |
| Settings | one sheet, stepping into playback speed (0.25x–2x) and quality |
| Markers | timed cues that pause the video, show a panel, and resume |
| Fullscreen | a route, not a device rotation — works in a portrait-locked app |
| Auto-hide | controls time out while playing and stay up while not |

## Using it

Install `FullscreenRotation.builder` once, so fullscreen can turn the widget
tree in an app that is locked to portrait:

```dart
MaterialApp(
  builder: FullscreenRotation.builder,   // must be above the Navigator
  home: const HomeScreen(),
);
```

Then wrap your player's widget:

```dart
VideoSkin(
  adapter: myAdapter,
  surface: MyBackendPlayer(controller: myController),
  title: 'Lesson 3 — Kinematics',
  accentColor: const Color(0xFFFF3B30),
  markers: const [
    VideoMarker(
      time: Duration(minutes: 2),
      title: 'Checkpoint',
      body: 'Playback resumes on its own.',
      duration: Duration(seconds: 5),
    ),
  ],
  onBack: () => Navigator.of(context).maybePop(),
)
```

`surface` is your backend's video widget. It is mounted underneath the controls
and stays mounted while fullscreen is up — the fullscreen page gets its picture
from `adapter.buildFullscreenSurface` instead.

If your backend cannot produce a controller until it has resolved the source —
most packages resolve asynchronously — use `VideoSkin.deferred` and a notifier:

```dart
final _adapter = ValueNotifier<VideoPlaybackAdapter?>(null);

VideoSkin.deferred(
  adapter: _adapter,
  surface: MyBackendPlayer(onReady: (c) => _adapter.value = MyAdapter(c)),
  sourceFailed: _sourceFailed,   // optional; drives the loading page's error
)
```

Until an adapter arrives the skin draws no controls, so your backend's own
loading widget shows through — but a swipe up still goes fullscreen over the
loader, and hands the video over to the real fullscreen page the moment it is
ready.

### Options

| Parameter | Default | |
|---|---|---|
| `title` | – | shown in the control bar |
| `aspectRatio` | `16/9` | the inline box, before the video's ratio is known |
| `accentColor` | red | progress bar, play button, ticked option |
| `markers` | `[]` | timed cues; read once, on first build |
| `onBack` | – | back button inline; omit it and none is drawn |
| `onFullscreenChanged` | – | for a host that hides its own app bar |
| `onFullscreenHandover` | – | see `VideoSkin.onFullscreenHandover` |
| `sourceFailed` | – | a failure that happens before there is an adapter |
| `rotateOnFullscreen` | `true` | off for an app that rotates with the device |

## Writing an adapter

Extend `VideoPlaybackAdapter`, hold the real controller inside, and forward.
Everything has a working default except the eight members below, so a minimal
adapter is short.

**Required**

| Member | |
|---|---|
| `position`, `duration` | where the playhead is, and how long the video is |
| `isPlaying` | whether frames are moving |
| `play()`, `pause()`, `seekTo()` | the three commands nothing works without |
| `buildFullscreenSurface()` | the picture, for the fullscreen route |
| `notifyListeners()` | called whenever any of the above changes |

**Worth overriding**

`isBuffering`, `isFinished`, `isMuted`, `playbackSpeed`, `hasError`,
`isDisposed`, `bufferedFraction`, `aspectRatio`, `capabilities`, `replay()`,
`setMuted()`, `setPlaybackSpeed()`, `availableQualities`, `currentQuality`,
`setQuality()`, `previewSourceUrl`, `isFullscreen`, `toggleFullscreen()`,
`reassertsPlaybackAfterRateChange`.

### The three rules

**1. Notify on every change.** The skin rebuilds from `notifyListeners()` and
from nothing else. If your controller is a `ChangeNotifier`, forward it in the
constructor:

```dart
MyAdapter(this.controller) {
  controller.addListener(notifyListeners);
}
```

If it exposes streams, subscribe and notify. If it exposes neither, poll on a
`Timer.periodic` of about 200ms — the position readout and the progress bar move
at that rate.

**2. Declare what the source can do.** `capabilities` is read on every build, so
it may widen as the source resolves. A capability that is off removes its
control rather than disabling it:

```dart
@override
PlaybackCapabilities get capabilities => PlaybackCapabilities(
  seek: !controller.isLive,
  playbackSpeed: true,
  quality: controller.tracks.length > 1,
  mute: true,
  fullscreen: true,
);
```

**3. Move the surface, don't build a second one.** Fullscreen is a route pushed
over the inline player, so the inline surface is still mounted underneath.
A backend that can only have one live surface must move it across —
`OmniPlaybackAdapter` hands the package's own player widget through a notifier —
because building a second restarts playback, or duplicates a `GlobalKey` and
throws.

### Fullscreen

The default `toggleFullscreen` pushes an opaque, un-animated route and pops it
again. That is right for any backend that does not care.

Override it when the player has its own idea of fullscreen that must stay in
step — a controller flag that gates which widget tree renders the video, or a
platform call. An override must call `onChanged(true)` before the page goes up
and `onChanged(false)` once it has come down, exactly once each, and must not
return until the page has been popped.

### Quality

Backends name their renditions in their own way, so `VideoQuality` carries both
the backend's key (`id`) and the text the user reads (`label`). Return them
highest first from `availableQualities`; `setQuality` gets one of them back.

```dart
@override
List<VideoQuality> get availableQualities => [
  for (final track in controller.tracks)
    VideoQuality(id: track.id, label: '${track.height}p', height: track.height),
];

@override
Future<void> setQuality(VideoQuality quality) =>
    controller.selectTrack(quality.id);
```

`setQuality` should not complete until the new rendition is playing — the skin
holds a spinner over the video and suppresses timed cues for the whole call,
because a swap that tears the stream down moves the playhead for reasons that
have nothing to do with playback.

### Scrub previews

Return a URL the platform frame extractor can read from `previewSourceUrl` —
usually the stream that is playing — and the scrub bubble shows still frames.
Leave it null (the default) for a source behind a WebView or DRM, and the bubble
shows its timestamp alone.

### Quirk switches

`reassertsPlaybackAfterRateChange` is off by default. Turn it on only if your
backend can strand playback across a speed or quality change; the skin will then
watch for the stall and call `play()` again until frames are flowing, standing
down the moment the user touches a control. `OmniPlaybackAdapter` needs it —
that package's audio/video sync engine pauses the video when the audio track
re-buffers and its watchdog stops with it. A well-behaved backend does not.

## A worked example: TPStreams

`tpstreams_player_sdk` exposes a `TpStreamPlayerController` with a
`VideoPlayerController`-shaped `value`. Adapting it is one file:

```dart
import 'package:flutter/material.dart';
import 'package:tpstreams_player_sdk/tpstreams_player_sdk.dart';
import 'package:video_skin/video_skin.dart';

/// Drives [VideoSkin] from a TPStreams controller.
class TPStreamsPlaybackAdapter extends VideoPlaybackAdapter {
  TPStreamsPlaybackAdapter(this.controller) {
    controller.addListener(notifyListeners);
  }

  final TpStreamPlayerController controller;

  @override
  void dispose() {
    controller.removeListener(notifyListeners);
    super.dispose();
  }

  // ── state
  @override
  Duration get position => controller.value.position;

  @override
  Duration get duration => controller.value.duration;

  @override
  bool get isPlaying => controller.value.isPlaying;

  @override
  bool get isBuffering => controller.value.isBuffering;

  @override
  bool get isFinished =>
      duration > Duration.zero && position >= duration;

  @override
  bool get isMuted => controller.value.volume == 0;

  @override
  double get playbackSpeed => controller.value.playbackSpeed;

  @override
  bool get hasError => controller.value.hasError;

  @override
  double get aspectRatio => controller.value.aspectRatio;

  @override
  double get bufferedFraction {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    var furthest = Duration.zero;
    for (final range in controller.value.buffered) {
      if (range.end > furthest) furthest = range.end;
    }
    return furthest.inMilliseconds / total;
  }

  /// Live streams cannot be seeked, and DRM playback exposes no readable URL,
  /// so previews are off for it — see [previewSourceUrl].
  @override
  PlaybackCapabilities get capabilities => PlaybackCapabilities(
        seek: !controller.value.isLive,
        quality: controller.availableVideoTracks.length > 1,
      );

  // ── commands
  @override
  Future<void> play() => controller.play();

  @override
  Future<void> pause() => controller.pause();

  @override
  Future<void> seekTo(Duration position) => controller.seekTo(position);

  @override
  Future<void> setMuted(bool muted) => controller.setVolume(muted ? 0 : 1);

  @override
  Future<void> setPlaybackSpeed(double speed) =>
      controller.setPlaybackSpeed(speed);

  // ── quality
  @override
  List<VideoQuality> get availableQualities => [
        for (final track in controller.availableVideoTracks)
          VideoQuality(
            id: track.id,
            label: '${track.height}p',
            height: track.height,
          ),
      ];

  @override
  VideoQuality? get currentQuality {
    final track = controller.selectedVideoTrack;
    if (track == null) return null;
    return VideoQuality(
      id: track.id,
      label: '${track.height}p',
      height: track.height,
    );
  }

  @override
  Future<void> setQuality(VideoQuality quality) =>
      controller.setVideoTrack(quality.id);

  // ── previews: DRM-protected streams cannot be read by the frame extractor.
  @override
  String? get previewSourceUrl =>
      controller.isDrmProtected ? null : controller.streamUrl;

  // ── fullscreen: TPStreams renders through a plain platform view, so a second
  // one in the fullscreen route would be a second decoder. Move the widget.
  @override
  Widget buildFullscreenSurface(BuildContext context) =>
      TPStreamsPlayerView(controller: controller);
}
```

Then the screen is the same as any other:

```dart
VideoSkin(
  adapter: TPStreamsPlaybackAdapter(controller),
  surface: TPStreamsPlayerView(controller: controller),
  title: lesson.title,
  markers: lesson.checkpoints,
)
```

> The listing above is written against the SDK's documented API and has not been
> compiled against it here. Member names may need adjusting; the shape will not.

`OmniPlaybackAdapter` in the host app
(`lib/player/backends/omni_playback_adapter.dart`) is the same job done against
`omni_video_player`, and it is compiled and exercised — read it alongside this.

## Testing an adapter

`test/fake_playback_adapter.dart` is a complete adapter in about a hundred lines,
backed by plain fields and a list of recorded calls. Copy it as a starting point:
it is the shortest illustration of the interface there is, and it lets the whole
skin be driven in widget tests with no platform channel involved.

## Layout

```
lib/
  video_skin.dart                    the barrel; export this
  src/
    playback/
      playback_adapter.dart          VideoPlaybackAdapter — the seam
      playback_capabilities.dart     what a source can be asked to do
      video_quality.dart             a rendition, backend-neutral
    markers/
      video_marker.dart              VideoMarker, VideoMarkerController, CueHold
    preview/
      scrub_preview.dart             pulls still frames for the scrub bubble
    widgets/
      video_skin.dart                the wrapper: surface + controls + fullscreen
      player_controls.dart           every button, bar and gesture
      video_progress_bar.dart        the scrubbable bar
      marker_overlay.dart            the panel a cue puts over the video
      fullscreen_rotation.dart       turns the tree, not the device
```
