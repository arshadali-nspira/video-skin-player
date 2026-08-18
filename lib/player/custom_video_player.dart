import 'package:flutter/material.dart';
import 'package:omni_video_player/omni_video_player.dart';
import 'package:video_skin/video_skin.dart';

import 'backends/omni_playback_adapter.dart';
import 'video_source.dart';
import 'youtube_link.dart';

/// Plays a video from a link, with [VideoSkin] on top of it.
///
/// This is the `omni_video_player` *backend* and nothing more: it resolves the
/// source, mounts the package's player with every stock affordance switched off,
/// and hands the resulting controller to the skin as an [OmniPlaybackAdapter].
/// Every control the user sees, every gesture they make and the fullscreen page
/// itself belong to the skin, which knows nothing about this package.
///
/// Takes a YouTube link (or bare video ID) or a direct media URL — an .mp4, an
/// .m3u8 HLS playlist, anything the platform player can open. Which one it is is
/// decided by [classifyVideoInput]; nothing else about the player changes.
///
/// Fullscreen does not rotate the device: the app stays locked to portrait and
/// the widget tree is turned instead. That needs [FullscreenRotation.builder]
/// installed as `MaterialApp.builder`.
class CustomVideoPlayer extends StatefulWidget {
  const CustomVideoPlayer({
    super.key,
    required this.url,
    this.title,
    this.autoPlay = true,
    this.startAt,
    this.aspectRatio = 16 / 9,
    this.accentColor = const Color(0xFFFF3B30),
    this.markers = const [],
    this.onBack,
    this.onAdapterReady,
  });

  /// A YouTube link in any common form, a bare 11-character video ID, or a
  /// direct http(s) media URL.
  final String url;

  /// Shown in the control bar.
  final String? title;

  final bool autoPlay;

  /// Position to start playback from.
  final Duration? startAt;

  /// Used for the inline box before the video's own ratio is known.
  final double aspectRatio;

  /// Drives the progress bar, the play button and the ticked settings option.
  final Color accentColor;

  /// Timed cues: each is a tick on the progress bar, and an overlay that
  /// interrupts playback for its own duration when the video plays through it.
  final List<VideoMarker> markers;

  /// Invoked by the control bar's back button while not in fullscreen.
  final VoidCallback? onBack;

  /// Escape hatch for driving playback from outside the player.
  final ValueChanged<VideoPlaybackAdapter>? onAdapterReady;

  @override
  State<CustomVideoPlayer> createState() => _CustomVideoPlayerState();
}

class _CustomVideoPlayerState extends State<CustomVideoPlayer> {
  /// Carries the adapter to the skin, which is built before the package has
  /// resolved the source and produced a controller.
  final _adapter = ValueNotifier<VideoPlaybackAdapter?>(null);

  OmniPlaybackAdapter? _owned;

  /// Whether the source failed outright.
  ///
  /// The package offers no error callback, and a source that never resolves
  /// never produces a controller — so the one signal available is it building
  /// the error placeholder, which is a widget of ours. The skin's loading
  /// fullscreen page watches this, so a swipe made over a dead link ends in the
  /// same message the inline player shows rather than a spinner that never
  /// stops.
  final _sourceFailed = ValueNotifier<bool>(false);

  /// Built once and never rebuilt.
  ///
  /// [VideoPlayerConfiguration] mints fresh [GlobalKey]s in its constructor, so
  /// handing the player a new instance on a later build would remount it and
  /// restart playback.
  late final VideoPlayerConfiguration _configuration = _buildConfiguration();

  @override
  void dispose() {
    _owned?.dispose();
    _adapter.dispose();
    _sourceFailed.dispose();
    super.dispose();
  }

  /// Picks the source the URL calls for.
  ///
  /// The quality lists only mean something where there are variants to choose
  /// between — YouTube's separate streams, or an HLS playlist. For a plain .mp4
  /// they are ignored.
  VideoSourceConfiguration _buildSource() {
    const qualities = [OmniVideoQuality.high720, OmniVideoQuality.medium480];
    final kind = classifyVideoInput(widget.url);

    final source = switch (kind) {
      VideoSourceKind.youtube => VideoSourceConfiguration.youtube(
        videoUrl: Uri.parse(youtubeWatchUrl(widget.url)),
        preferredQualities: qualities,
      ),
      // A malformed string lands here too. The player surfaces the failure
      // through its error placeholder rather than throwing during build.
      VideoSourceKind.network || null => VideoSourceConfiguration.network(
        videoUrl: Uri.parse(widget.url.trim()),
        preferredQualities: qualities,
      ),
    };

    return source.copyWith(
      autoPlay: widget.autoPlay,
      initialPosition: widget.startAt ?? Duration.zero,
      // The player sits at the top of its page and never scrolls away, so the
      // only thing that ever stops it being painted is a fullscreen page going
      // up over it. Left on, the package reads that as the video having scrolled
      // off and throws the controller away mid-swipe — the skin covers the
      // player with its loading page before the package knows about fullscreen.
      pauseWhenOutOfView: false,
    );
  }

  VideoPlayerConfiguration _buildConfiguration() {
    return VideoPlayerConfiguration(
      videoSourceConfiguration: _buildSource(),

      // Everything the package would draw, off — except the two things that
      // have to exist before there is a controller for the skin to drive: the
      // loading widget, and the error placeholder. A source that fails to
      // resolve never produces a controller, so the skin's own error state can
      // never be reached; without the placeholder a dead URL is just a black
      // box.
      playerUIVisibilityOptions: const PlayerUIVisibilityOptions(
        showVideoBottomControlsBar: false,
        showPlayPauseReplayButton: false,
        showReplayButton: false,
        showSeekBar: false,
        showCurrentTime: false,
        showDurationTime: false,
        showRemainingTime: false,
        showFullScreenButton: false,
        showMuteUnMuteButton: false,
        showSwitchVideoQuality: false,
        showPlaybackSpeedButton: false,
        showThumbnailAtStart: false,
        showGradientBottomControl: false,
        // The skin's, in PlayerControls. Leaving the package's on as well would
        // mean two recognisers fighting over the same tap.
        enableForwardGesture: false,
        enableBackwardGesture: false,
        enableExitFullscreenOnVerticalSwipe: false,
        enableZoom: false,
      ),
      playerTheme: OmniVideoPlayerThemeData(
        colors: VideoPlayerColorScheme(
          backgroundThumbnail: Colors.black,
          controlButtonIcon: widget.accentColor,
        ),
      ),
      customPlayerWidgets: CustomPlayerWidgets(
        loadingWidget: CircularProgressIndicator(
          color: widget.accentColor,
          strokeWidth: 3,
        ),
        errorPlaceholder: _SourceError(onShown: _onSourceFailed),
      ),
    );
  }

  void _onControllerCreated(OmniPlaybackController controller) {
    final adapter = OmniPlaybackAdapter(controller);
    _owned = adapter;
    _adapter.value = adapter;
    widget.onAdapterReady?.call(adapter);
  }

  /// Starts the playback the package would have started for itself.
  ///
  /// Its autoplay does not run on the controller being ready — it runs from the
  /// *inline* view's visibility, on the frame that view reports itself fully on
  /// screen. The skin's fullscreen loading page is covering that view, so the
  /// frame never comes, and a video that loaded behind it would sit on its first
  /// frame waiting to be tapped.
  ///
  /// Only reached on that hand-over path. Left inline, the package's own
  /// autoplay works, and [OmniPlaybackController.hasStarted] keeps this from
  /// overriding a video the user has already paused.
  void _onFullscreenHandover() {
    final controller = _owned?.controller;
    if (controller == null) return;
    if (!widget.autoPlay || controller.hasStarted) return;
    controller.play();
  }

  /// The package has given up on the source. Deferred, because the placeholder
  /// is built during a build phase and this notifies listeners.
  void _onSourceFailed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sourceFailed.value = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return VideoSkin.deferred(
      adapter: _adapter,
      title: widget.title,
      aspectRatio: widget.aspectRatio,
      accentColor: widget.accentColor,
      markers: widget.markers,
      onBack: widget.onBack,
      sourceFailed: _sourceFailed,
      onFullscreenHandover: _onFullscreenHandover,
      surface: OmniVideoPlayer(
        configuration: _configuration,
        callbacks: VideoPlayerCallbacks(
          onControllerCreated: _onControllerCreated,
        ),
      ),
    );
  }
}

/// Shown when the source never resolves — a dead link, a 403, an unplayable
/// container, or no network.
///
/// Styled to match the skin's own error state, which covers the other half: a
/// failure that happens once playback is already under way.
class _SourceError extends StatefulWidget {
  const _SourceError({this.onShown});

  /// Fired when this is first built, which is the package's only outward sign
  /// that a source has failed for good.
  final VoidCallback? onShown;

  @override
  State<_SourceError> createState() => _SourceErrorState();
}

class _SourceErrorState extends State<_SourceError> {
  @override
  void initState() {
    super.initState();
    widget.onShown?.call();
  }

  @override
  Widget build(BuildContext context) => const SourceErrorBody();
}
