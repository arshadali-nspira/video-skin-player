/// A custom video control surface that is not tied to any one player package.
///
/// [VideoSkin] draws the controls, the scrubber and its frame previews, the
/// timed marker overlays, the gestures and fullscreen; a
/// [VideoPlaybackAdapter] connects all of that to whatever is actually playing
/// the video. Nothing in this library imports a player package, so a new
/// backend is one subclass and no changes here.
///
/// See `README.md` for a walk-through and a worked example adapter.
library;

export 'src/markers/video_marker.dart';
export 'src/playback/playback_adapter.dart';
export 'src/playback/playback_capabilities.dart';
export 'src/playback/video_quality.dart';
export 'src/preview/scrub_preview.dart';
export 'src/widgets/fullscreen_rotation.dart';
export 'src/widgets/marker_overlay.dart';
export 'src/widgets/player_controls.dart';
export 'src/widgets/video_progress_bar.dart';
export 'src/widgets/video_skin.dart';
