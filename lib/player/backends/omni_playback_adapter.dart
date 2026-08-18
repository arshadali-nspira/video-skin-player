import 'package:flutter/material.dart';
import 'package:omni_video_player/omni_video_player.dart';
import 'package:video_skin/video_skin.dart';

/// Drives [VideoSkin] from an `omni_video_player` controller.
///
/// One of two backends the skin has been used with, and the reference for
/// writing another: everything specific to the package lives in this file, and
/// nothing under `packages/video_skin` knows the package exists.
///
/// The controller is not owned here — `omni_video_player` creates and disposes
/// it. This only listens to it and translates.
class OmniPlaybackAdapter extends VideoPlaybackAdapter {
  OmniPlaybackAdapter(this.controller) {
    controller.addListener(notifyListeners);
  }

  /// The package's controller, handed over by `onControllerCreated`.
  final OmniPlaybackController controller;

  @override
  void dispose() {
    // Guarded: the package disposes the controller on its own schedule, and a
    // controller already gone throws on removeListener.
    if (!controller.isDisposed) controller.removeListener(notifyListeners);
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────── playback state

  @override
  Duration get position => controller.currentPosition;

  @override
  Duration get duration => controller.duration;

  @override
  bool get isPlaying => controller.isPlaying;

  @override
  bool get isBuffering => controller.isBuffering;

  @override
  bool get isFinished => controller.isFinished;

  @override
  bool get isMuted => controller.isMuted;

  @override
  double get playbackSpeed => controller.playbackSpeed;

  @override
  bool get hasError => controller.hasError;

  @override
  bool get isDisposed => controller.isDisposed;

  /// The furthest buffered point, as a fraction of the whole video.
  ///
  /// The package reports ranges; the skin wants one number, and the only one
  /// that means anything to a progress bar is how far ahead it is safe to play.
  @override
  double get bufferedFraction {
    final total = controller.duration;
    if (total <= Duration.zero) return 0;
    var furthest = Duration.zero;
    for (final range in controller.buffered) {
      if (range.end > furthest) furthest = range.end;
    }
    return furthest.inMilliseconds / total.inMilliseconds;
  }

  /// The video's own ratio, corrected for a rotated recording.
  @override
  double get aspectRatio {
    final size = controller.size;
    if (size.width <= 0 || size.height <= 0) return 16 / 9;
    final rotated =
        controller.rotationCorrection == 90 ||
        controller.rotationCorrection == 270;
    return rotated ? size.height / size.width : size.width / size.height;
  }

  /// Seeking is the only one the package qualifies: it reports false where the
  /// platform is known to stall instead of seek — WebM in a WebView on iOS.
  @override
  PlaybackCapabilities get capabilities =>
      PlaybackCapabilities(seek: controller.supportsSeek);

  // ───────────────────────────────────────────────────────────────── commands

  @override
  Future<void> play() => controller.play();

  @override
  Future<void> pause() => controller.pause();

  @override
  Future<void> seekTo(Duration position) async => controller.seekTo(position);

  @override
  Future<void> replay() => controller.replay();

  @override
  Future<void> setMuted(bool muted) async {
    if (muted) {
      controller.mute();
    } else {
      controller.unMute();
    }
  }

  @override
  Future<void> setPlaybackSpeed(double speed) =>
      controller.setPlaybackSpeed(speed);

  // ────────────────────────────────────────────────────────────────── quality

  /// The package's qualities, highest first, with `unknown` dropped — it is
  /// what a DASH stream reports for a rendition it could not identify, and it
  /// has no label worth showing.
  @override
  List<VideoQuality> get availableQualities {
    final available = controller.availableVideoQualities ?? const [];
    final selectable =
        available.where((q) => q != OmniVideoQuality.unknown).toList()
          ..sort((a, b) => a.compareTo(b));
    return [for (final quality in selectable) _toQuality(quality)];
  }

  /// What is playing now.
  ///
  /// Falls back to the video's own height when the package reports no quality —
  /// a plain .mp4 is one file and has none — so a single-rendition source still
  /// says what it is rather than showing a dash.
  @override
  VideoQuality? get currentQuality {
    final current = controller.currentVideoQuality;
    if (current != null && current != OmniVideoQuality.unknown) {
      return _toQuality(current);
    }
    final height = controller.size.height;
    if (height <= 0) return null;
    return VideoQuality(
      id: 'intrinsic',
      label: '${height.round()}p',
      height: height.round(),
    );
  }

  @override
  Future<void> setQuality(VideoQuality quality) {
    return controller.switchQuality(
      omniVideoQualityFromString(quality.label),
    );
  }

  static VideoQuality _toQuality(OmniVideoQuality quality) {
    final label = quality.qualityString;
    return VideoQuality(
      id: quality.name,
      label: label,
      height: int.tryParse(label.replaceAll('p', '')),
    );
  }

  // ────────────────────────────────────────────────────────── scrub previews

  /// The stream the player resolved, which the platform frame extractor can
  /// read too.
  ///
  /// Null on the YouTube WebView path, which plays through an iframe and never
  /// exposes one. The skin falls back to timestamps on their own.
  @override
  String? get previewSourceUrl => controller.videoUrl?.toString();

  // ─────────────────────────────────────────────────────────────── fullscreen

  /// The package's own flag, not the skin's.
  ///
  /// The inline and fullscreen viewports both gate on it to decide which of them
  /// renders the single shared player widget, so the two must never disagree.
  @override
  bool get isFullscreen => controller.isFullScreen;

  /// Handed to the package rather than pushed here, so its flag flips with the
  /// route. Its signature is the skin's, near enough, so this is a forward.
  @override
  Future<void> toggleFullscreen(
    BuildContext context, {
    required WidgetBuilder pageBuilder,
    required ValueChanged<bool> onChanged,
  }) {
    return controller.switchFullScreenMode(
      context,
      pageBuilder: pageBuilder,
      onToggle: onChanged,
    );
  }

  /// The live player widget, moved across rather than rebuilt.
  ///
  /// [OmniPlaybackController.sharedPlayerNotifier] is the package's own handle
  /// for carrying the player between widget trees, so playback continues across
  /// the transition. Exactly one tree may render it at a time — it carries
  /// global keys — which is what the [isFullScreen] gate is for: without it the
  /// inline viewport and this one overlap while the route animates and the tree
  /// gets a duplicate key.
  @override
  Widget buildFullscreenSurface(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, controller.sharedPlayerNotifier]),
      builder: (context, _) {
        if (!controller.isFullScreen) return const SizedBox.expand();
        return controller.sharedPlayerNotifier.value ?? const SizedBox.expand();
      },
    );
  }

  // ───────────────────────────────────────────────────────────── quirk switches

  /// The package strands playback across a speed change: raising the speed
  /// after a spell at a slow one makes the audio track re-buffer, its
  /// audio/video sync engine pauses the video, and its 200ms watchdog stops with
  /// it — so the buffer filling is never noticed and the video stays paused for
  /// good. `1x → 0.25x → wait → 1.25x` reproduces it every time. Nothing inside
  /// the package recovers, so the skin re-asserts playback for it.
  @override
  bool get reassertsPlaybackAfterRateChange => true;
}
