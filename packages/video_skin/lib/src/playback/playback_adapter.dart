import 'package:flutter/material.dart';

import 'playback_capabilities.dart';
import 'video_quality.dart';

/// The seam between the control surface and whatever is actually playing the
/// video.
///
/// Everything the skin draws it draws from an adapter, and every command the
/// user issues it issues through one. Nothing under `video_skin` knows which
/// player package is underneath, so a second backend — TPStreams, `video_player`,
/// an HLS SDK, a WebView — is a subclass of this and nothing else.
///
/// ## Implementing one
///
/// Extend this, hold the real controller inside, and:
///
///  * forward its change notifications by calling [notifyListeners] — the skin
///    rebuilds from those and from nothing else. A backend that only exposes
///    streams should listen to them and notify; one that exposes nothing should
///    poll on a timer;
///  * override the state getters to read the real controller. They are read
///    during build, so they must be cheap and must not throw once
///    [isDisposed] is true;
///  * override the commands. They may complete before the underlying player has
///    caught up: the skin mirrors the state it asked for and ignores contrary
///    reports briefly, so a command that lands late does not make the UI jump;
///  * declare what the source can do through [capabilities], and
///  * build the fullscreen video surface in [buildFullscreenSurface].
///
/// Everything else has a working default. A minimal adapter overrides eight
/// getters and five commands.
///
/// ## What an adapter must not do
///
/// It must not draw. The inline video surface is passed to [VideoSkin] by the
/// widget that owns the backend, the fullscreen one comes from
/// [buildFullscreenSurface], and every control on top of both is the skin's.
abstract class VideoPlaybackAdapter extends ChangeNotifier {
  // ─────────────────────────────────────────────────────────── playback state

  /// Where the playhead is now.
  ///
  /// Reported continuously; the skin holds its own copy steady while the user
  /// scrubs and for a moment after a seek, so a stale report cannot snap the
  /// bar backwards.
  Duration get position;

  /// The whole video's length, or [Duration.zero] until it is known.
  ///
  /// Zero disables the scrubber and shows `--:--` for the total, so returning
  /// it early is safe.
  Duration get duration;

  /// How much has been buffered, as a fraction of [duration] in `0..1`.
  ///
  /// The furthest buffered point, not the sum of the ranges. Defaults to zero,
  /// which simply leaves the buffered track unpainted.
  double get bufferedFraction => 0;

  bool get isPlaying;

  /// Whether the player is filling its buffer. Puts a spinner over the picture
  /// and withholds the play button, which would otherwise invite a tap that
  /// does nothing.
  bool get isBuffering => false;

  /// Whether playback has run to the end. Turns the play button into a replay
  /// button and keeps the controls up.
  bool get isFinished => false;

  bool get isMuted => false;

  /// `1` for normal speed. Only meaningful when
  /// [PlaybackCapabilities.playbackSpeed] is on.
  double get playbackSpeed => 1;

  /// Whether playback has failed for good. Puts the error panel over
  /// everything, so return true only when there is nothing left to try.
  bool get hasError => false;

  /// Whether this adapter — or the controller under it — has been torn down.
  ///
  /// The skin checks this before commands that run on a timer, so a late one
  /// cannot reach a dead controller.
  bool get isDisposed => false;

  /// The video's own shape, corrected for a rotated recording.
  ///
  /// Used to letterbox the fullscreen page. Defaults to 16:9, which is also
  /// what to return before the real ratio is known.
  double get aspectRatio => 16 / 9;

  /// What this source can be asked to do. Read on every build, so a backend
  /// may widen it as the source resolves.
  PlaybackCapabilities get capabilities => const PlaybackCapabilities();

  // ───────────────────────────────────────────────────────────────── commands

  /// Starts or resumes playback.
  Future<void> play();

  Future<void> pause();

  /// Moves the playhead. Called repeatedly while scrubbing — the skin throttles
  /// to one call every 120ms and always issues a final one on release, so an
  /// implementation does not need to throttle again.
  ///
  /// [position] is already clamped to `0..duration`.
  Future<void> seekTo(Duration position);

  /// Plays from the beginning after the video has finished.
  ///
  /// Defaults to a seek to zero followed by [play], which is right for most
  /// backends.
  Future<void> replay() async {
    await seekTo(Duration.zero);
    await play();
  }

  /// Silences or unsilences the audio.
  ///
  /// Only called when [PlaybackCapabilities.mute] is on; the default does
  /// nothing so a backend without a mute can leave it alone.
  Future<void> setMuted(bool muted) async {}

  /// Sets the playback rate, where `1` is normal speed.
  ///
  /// Only called when [PlaybackCapabilities.playbackSpeed] is on.
  Future<void> setPlaybackSpeed(double speed) async {}

  // ────────────────────────────────────────────────────────────────── quality

  /// The renditions the user may choose between, highest first.
  ///
  /// Return fewer than two and the quality row goes inert — there is nothing to
  /// switch to — while still reading out [currentQuality].
  List<VideoQuality> get availableQualities => const [];

  /// The rendition playing now, ticked in the list. Null shows a dash.
  VideoQuality? get currentQuality => null;

  /// Switches rendition, and completes when the new one is playing.
  ///
  /// The skin holds a spinner over the video for the whole call and suppresses
  /// timed cues, because a swap that tears the stream down and rebuilds it
  /// moves the playhead about for reasons that have nothing to do with playback.
  ///
  /// [quality] is one of [availableQualities], so [VideoQuality.id] can be
  /// looked straight back up.
  Future<void> setQuality(VideoQuality quality) async {}

  // ────────────────────────────────────────────────────────── scrub previews

  /// A URL the platform frame extractor can read, for the thumbnails shown
  /// above the scrubber.
  ///
  /// Usually the same stream that is playing. Null — the default — leaves the
  /// scrub bubble showing its timestamp alone, which is the right answer for a
  /// source that plays through a WebView or a DRM pipeline and never exposes a
  /// readable URL. Change it when the stream changes, and the skin rebuilds the
  /// preview against the new one.
  String? get previewSourceUrl => null;

  /// Sent with the frame requests, for a source that will not serve a bare GET.
  Map<String, String>? get previewHeaders => null;

  // ─────────────────────────────────────────────────────────────── fullscreen

  /// Whether the video currently owns the whole screen.
  ///
  /// Kept by the default [toggleFullscreen]. A backend whose own controller
  /// tracks fullscreen should override this to read that instead, so the two
  /// cannot disagree.
  bool get isFullscreen => _isFullscreen;
  bool _isFullscreen = false;

  /// Renders the video inside the skin's fullscreen page.
  ///
  /// Fullscreen is a route pushed over the inline player, so the inline surface
  /// is still mounted underneath. A backend that can only have one live surface
  /// at a time must *move* it — publishing the one live widget through a
  /// notifier both trees read, as several packages already do — rather than
  /// building a second one, which would restart playback, or duplicate a
  /// [GlobalKey] and throw.
  ///
  /// Called on every rebuild of the fullscreen page.
  Widget buildFullscreenSurface(BuildContext context);

  /// Enters or leaves fullscreen, and reports which through [onChanged].
  ///
  /// The skin supplies the page and owns everything on it; this only decides how
  /// it goes up. The default pushes an opaque, un-animated route and pops it
  /// again, which suits any backend that does not care.
  ///
  /// Override when the player has its own idea of fullscreen that must be kept
  /// in step — a controller flag that gates which widget tree renders the video,
  /// or a platform call. An override must:
  ///
  ///  * call [onChanged] with true before the page goes up and false once it has
  ///    come down, exactly once each. The skin turns the app a quarter turn and
  ///    hides the system bars off those calls;
  ///  * not return until the page has been popped, since the skin awaits this to
  ///    know the move is over.
  ///
  /// [pageBuilder] must be built inside the new route, not captured and reused.
  Future<void> toggleFullscreen(
    BuildContext context, {
    required WidgetBuilder pageBuilder,
    required ValueChanged<bool> onChanged,
  }) async {
    if (_isFullscreen) {
      Navigator.of(context).pop();
      return;
    }
    _isFullscreen = true;
    notifyListeners();
    onChanged(true);

    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        // No transition, and opaque. The tree underneath is turning a quarter
        // circle at this moment, and anything that composites the two shows the
        // page below swinging through the middle of the screen.
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => pageBuilder(context),
      ),
    );

    if (isDisposed) return;
    _isFullscreen = false;
    notifyListeners();
    onChanged(false);
  }

  // ───────────────────────────────────────────────────────────── quirk switches

  /// Whether the skin should keep re-asserting playback for a few seconds after
  /// a speed or quality change.
  ///
  /// A workaround, off by default. Some backends strand playback across a rate
  /// change: raising the speed makes the audio track re-buffer, the audio/video
  /// sync engine pauses the video, and its own watchdog — which only runs while
  /// the video is playing — stops with it, so the buffer filling is never
  /// noticed and the video stays paused for good.
  ///
  /// Turn it on and the skin watches for the stall and calls [play] again until
  /// frames are flowing, giving up after six seconds and standing down the
  /// moment the user touches a control, so their own pause is never undone.
  bool get reassertsPlaybackAfterRateChange => false;
}
