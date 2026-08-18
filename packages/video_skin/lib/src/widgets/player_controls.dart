import 'dart:async';

import 'package:flutter/material.dart';

import '../markers/video_marker.dart';
import '../playback/playback_adapter.dart';
import '../playback/playback_capabilities.dart';
import '../playback/video_quality.dart';
import '../preview/scrub_preview.dart';
import 'marker_overlay.dart';
import 'video_progress_bar.dart';

/// Formats a duration as `m:ss`, or `h:mm:ss` for videos an hour or longer.
String formatDuration(Duration duration) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
  return '$minutes:${two(seconds)}';
}

/// Reads a vertical drag as a fullscreen intent: true to enter, false to leave,
/// null for a flick too slow to have been meant as one.
///
/// Top-level because two surfaces offer the gesture — [PlayerControls] once the
/// video is up, and the stand-in layer the player puts over its loading spinner
/// before that — and they have to feel like the same swipe.
bool? fullscreenIntentFromSwipe(DragEndDetails details) {
  final velocity = details.primaryVelocity ?? 0;
  if (velocity.abs() < 300) return null;
  return velocity < 0;
}

/// The control surface: every button, bar and gesture the user gets.
///
/// Knows nothing about who is playing the video. It reads state from a
/// [VideoPlaybackAdapter], issues every command through one, and leaves out
/// whatever that adapter's [PlaybackCapabilities] say the source cannot do.
///
/// Normally mounted by [VideoSkin], which owns the fullscreen move and the
/// marker controller these need. Built directly only by a host that wants the
/// controls without the rest of the skin.
///
/// The same widget backs both inline and fullscreen playback — the fullscreen
/// page builds another one with [isFullscreen] set.
class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.adapter,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.accentColor = const Color(0xFFFF3B30),
    this.title,
    this.onBack,
    this.markers,
    this.startVisible = false,
  });

  /// Where playback state is read from and commands are sent.
  final VideoPlaybackAdapter adapter;

  /// Whether the player currently occupies the whole screen.
  final bool isFullscreen;

  /// Enters or leaves fullscreen. Owned by the player, which has to push and
  /// pop a route to do it.
  ///
  /// The move rebuilds these controls from scratch, and [keepControls] is what
  /// the new copy mounts with. True for a press on the control layer, which is
  /// an action and leaves the controls up for the usual delay; false for the
  /// swipe, which is made on the video itself and should hand back a picture as
  /// bare as the one it was made on.
  final void Function({required bool keepControls}) onToggleFullscreen;

  final Color accentColor;

  final String? title;

  /// Invoked by the back button when not in fullscreen.
  final VoidCallback? onBack;

  /// The timed cues for this video, if it has any. Owned by the player, so the
  /// markers already shown are remembered across a move into fullscreen.
  final VideoMarkerController? markers;

  /// Whether the controls are already on screen when this mounts.
  ///
  /// False on arrival at a video, where the player should show the picture and
  /// nothing else. True for a copy that is replacing another one: moving in or
  /// out of fullscreen tears these controls down and builds them again, and
  /// without this the fresh copy has no idea the user just pressed something —
  /// so the button press that got them there would take the controls away
  /// instead of leaving them up for the usual delay.
  final bool startVisible;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  static const Duration _seekStep = Duration(seconds: 10);
  static const Duration _autoHideDelay = Duration(seconds: 3);

  /// Shortest gap between two live seeks while scrubbing.
  static const Duration _scrubSeekInterval = Duration(milliseconds: 120);
  static const List<double> _speeds = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

  /// How long to keep watching playback after a speed change, and how often.
  ///
  /// The stall can arrive a second or more after the change — see
  /// [_holdPlaying] — so a couple of quick probes are not enough; the whole
  /// window has to be watched.
  static const Duration _speedRecoveryWindow = Duration(seconds: 6);
  static const Duration _speedRecoveryInterval = Duration(milliseconds: 250);

  /// How far past the pre-switch position counts as "really playing again".
  ///
  /// Not zero: the swap restores the position it captured itself, which can sit
  /// a tick ahead of our mirrored copy, so a bare `>` can be true before a
  /// single new frame has been shown.
  static const Duration _framesFlowing = Duration(milliseconds: 150);

  Timer? _hideTimer;
  Timer? _seekFeedbackTimer;

  /// Pulls the frames shown above the thumb. Built on the first scrub rather
  /// than up front — it needs a resolved URL and a known duration, neither of
  /// which exists when the controls first mount, and a video nobody scrubs
  /// should never decode a frame.
  ScrubPreview? _preview;

  /// Whether playback was running when the current scrub began.
  ///
  /// A scrub pauses the video so the frames it lands on can be seen, and this
  /// is what decides whether releasing picks playback back up or leaves it
  /// paused where the user had already paused it.
  bool _resumeAfterScrub = false;

  /// When the last live seek went out, so a drag does not fire one per pixel.
  DateTime _lastScrubSeek = DateTime.fromMillisecondsSinceEpoch(0);

  /// Position updates arriving right after a seek still report the old
  /// position, which would snap the scrubber backwards. Ignore them briefly.
  DateTime _ignorePositionUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _buffered = 0;
  bool _playing = false;
  bool _buffering = false;
  bool _finished = false;
  bool _muted = false;
  double _playbackRate = 1;

  /// Set from [PlayerControls.startVisible] on mount, so arriving on a playing
  /// video shows only the video.
  ///
  /// They come up on the first tap, and on their own whenever playback is not
  /// running — a paused or finished video needs to offer a way to start it
  /// again.
  bool _controlsVisible = false;

  /// Whether the settings sheet is up, so a second press cannot stack another
  /// one on top of it.
  ///
  /// Nothing else consults it. The sheet is a modal route with its own barrier
  /// across the whole screen, so it neither hides the controls nor holds their
  /// delay — they time out behind it exactly as they would have without it.
  bool _sheetOpen = false;

  /// The open sheet's own context, kept so a cue can close it from out here.
  BuildContext? _sheetContext;

  bool _dragging = false;
  double _dragFraction = 0;

  /// Accumulated seconds for the double-tap seek indicator.
  int _seekFeedbackSeconds = 0;
  bool _seekFeedbackForward = true;

  /// Bumped by every play/pause command, so a settle probe from an earlier
  /// speed change can tell that the user has since taken over.
  int _playbackCommand = 0;

  /// Whether a quality swap is in flight.
  ///
  /// A backend that swaps by tearing the stream down pauses first and only
  /// builds the replacement afterwards, so for the first few seconds nothing is
  /// buffering — the old stream is simply paused. Going by
  /// [VideoPlaybackAdapter.isBuffering] alone therefore shows a play button for
  /// three or four seconds and only then a spinner, which reads as the video
  /// having stopped for no reason. This carries the busy state from the moment
  /// the user picks a quality until frames are flowing again.
  bool _switchingQuality = false;

  /// Where playback stood when the swap was requested.
  ///
  /// The swap is only over once the position has moved *past* this. Clearing on
  /// `isPlaying` alone is too early: the flag flips while the replacement
  /// texture has yet to render a frame, so the spinner comes off a surface
  /// that is still blank — which is the "paused, then a loader" everyone
  /// reports. Waiting for the position to advance waits for real frames.
  Duration _switchAnchor = Duration.zero;

  VideoPlaybackAdapter get _adapter => widget.adapter;

  /// What this source can be asked to do. Re-read rather than cached: a
  /// backend may widen its capabilities as the source resolves.
  PlaybackCapabilities get _caps => _adapter.capabilities;

  /// Whether a seek this widget issued is still landing.
  ///
  /// [_seekTo] pushes the deadline out on every seek. Until it passes, both the
  /// positions the controller reports and any stop in playback belong to the
  /// seek rather than to the user.
  bool get _seekSettling => DateTime.now().isBefore(_ignorePositionUntil);

  /// The marker whose overlay is currently up, if any. Mirrored from
  /// [PlayerControls.markers] so a build reads a field like everything else.
  VideoMarker? _marker;

  /// Whether the bars and buttons are on screen.
  ///
  /// A marker overlay takes the surface over for as long as it is up. The
  /// settings sheet does not: it is a route with its own barrier across the
  /// whole screen, so it already hides what is behind it, and taking the
  /// controls down as well made pressing the settings button read as dismissing
  /// them. They wait behind the barrier instead, and [_restartHideTimer] holds
  /// the delay for as long as the sheet has the user.
  bool get _showControlLayer => _controlsVisible && _marker == null;

  /// Whether the player is working rather than playing — buffering, or partway
  /// through a quality swap. Shows the spinner and withholds the play button,
  /// which would otherwise invite a tap that does nothing.
  bool get _busy => _buffering || _switchingQuality;

  @override
  void initState() {
    super.initState();
    _readAdapter();
    _adapter.addListener(_onAdapterChanged);
    // Picked up rather than assumed null: a cue raised while the controls were
    // being swapped for the fullscreen copy is still up, and belongs on screen
    // the moment this one mounts.
    _marker = widget.markers?.active;
    widget.markers?.addListener(_onMarkerChanged);
    _controlsVisible = widget.startVisible;
    if (_playing) _restartHideTimer();
  }

  @override
  void didUpdateWidget(PlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.adapter != widget.adapter) {
      oldWidget.adapter.removeListener(_onAdapterChanged);
      _adapter.addListener(_onAdapterChanged);
      _readAdapter();
    }
    if (oldWidget.markers != widget.markers) {
      oldWidget.markers?.removeListener(_onMarkerChanged);
      widget.markers?.addListener(_onMarkerChanged);
      _marker = widget.markers?.active;
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _preview?.dispose();
    widget.markers?.removeListener(_onMarkerChanged);
    _adapter.removeListener(_onAdapterChanged);
    super.dispose();
  }

  /// Mirrors the controller into local fields.
  ///
  /// Kept as a snapshot rather than read straight from the controller at build
  /// time, so a scrub or a just-issued seek can hold the displayed position
  /// steady while the controller catches up.
  void _readAdapter() {
    final a = _adapter;
    _playing = a.isPlaying;
    _buffering = a.isBuffering;
    _finished = a.isFinished;
    _muted = a.isMuted;
    _playbackRate = a.playbackSpeed;
    if (a.duration > Duration.zero) _duration = a.duration;
    _buffered = a.bufferedFraction.clamp(0.0, 1.0);

    if (!_dragging && !_seekSettling) _position = a.position;
  }

  void _onAdapterChanged() {
    if (!mounted) return;
    final wasPlaying = _playing;
    final wasFinished = _finished;
    setState(_readAdapter);

    // Frames are actually flowing again, so the swap is over — drop the
    // spinner now rather than when the call finally returns.
    if (_switchingQuality &&
        _playing &&
        _position > _switchAnchor + _framesFlowing) {
      _setSwitching(false);
    }

    // A marker overlay owns the surface, and the pause it made to put itself up
    // is not the user pausing — bringing the controls back for it would leave
    // them showing through the scrim, and still on screen once the cue has gone.
    if (widget.markers?.active != null) return;

    // Only act on an actual change of playback state. The controller notifies
    // for other reasons too — position ticks, buffering, quality changes — and
    // acting on every one would keep pulling the controls back up after they
    // had been dismissed.
    if (_finished && !wasFinished) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = true);
      return;
    }
    if (_playing == wasPlaying) return;

    if (_playing) {
      _restartHideTimer();
    } else if (!_busy && !_seekSettling) {
      // Playback is not running, so offer a way to start it again — unless the
      // player stopped it for itself. A quality swap, a buffer, and the stall a
      // seek makes while it lands are all the player working, not the user
      // pausing: the spinner already says so, and the play button is withheld
      // through all three anyway. Raising the controls for one of them would
      // put them back on screen a beat after a double-tap seek had just taken
      // them away, which is the whole reason this is guarded.
      _hideTimer?.cancel();
      setState(() => _controlsVisible = true);
    }
  }

  /// Marks the player as mid-swap, and holds cues for as long as it is.
  ///
  /// The two go together: a swap moves the playhead about for reasons that have
  /// nothing to do with playback — the package tears the stream down, which
  /// reports position zero, and puts it back with a seek — and a cue raised off
  /// that is a cue the video never actually reached.
  void _setSwitching(bool switching) {
    if (_switchingQuality == switching) return;
    setState(() {
      _switchingQuality = switching;
      if (switching) _switchAnchor = _adapter.position;
    });
    if (switching) {
      widget.markers?.hold(CueHold.transition);
    } else {
      widget.markers?.release(CueHold.transition);
    }
  }

  /// A cue has come up or gone down.
  ///
  /// The controls step aside for it rather than sitting behind the scrim, and
  /// stay down afterwards: the video is playing again, which is the state the
  /// user was already watching in.
  void _onMarkerChanged() {
    if (!mounted) return;
    final marker = widget.markers?.active;
    setState(() {
      _marker = marker;
      if (marker != null) _controlsVisible = false;
    });
    if (marker != null) {
      _hideTimer?.cancel();
      // The sheet is a route above the player, so a cue raised underneath it
      // would come and go unseen. The cue interrupts the sheet, the way it
      // interrupts playback.
      _closeSheet();
    } else {
      _restartHideTimer();
    }
  }

  /// The markers, as fractions of the duration, for the progress bar.
  ///
  /// Empty until the duration is known — a fraction of nothing is nowhere — and
  /// markers past the end of the video are left off.
  List<double> get _markerFractions {
    final markers = widget.markers?.markers ?? const <VideoMarker>[];
    if (markers.isEmpty || _duration <= Duration.zero) return const [];
    return [
      for (final marker in markers)
        if (marker.time <= _duration)
          marker.time.inMilliseconds / _duration.inMilliseconds,
    ];
  }

  // ---------------------------------------------------------------- visibility

  void _restartHideTimer() {
    _hideTimer?.cancel();
    // Never while a finger is on the scrubber. The controls are what that
    // finger is holding — taking them away mid-drag pulls the bar and its
    // preview out from under it. [_onAdapterChanged] restarts this timer on
    // every change of playback state, buffering after a seek included, so
    // without this guard a long scrub loses the controls part-way through.
    if (!_playing || _dragging) return;
    _hideTimer = Timer(_autoHideDelay, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _restartHideTimer();
  }

  void _onSurfaceTap() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  // ------------------------------------------------------------------ commands

  void _seekTo(Duration target) {
    if (!_caps.seek) return;
    var clamped = target < Duration.zero ? Duration.zero : target;
    if (_duration > Duration.zero && clamped > _duration) clamped = _duration;

    setState(() {
      _position = clamped;
      _finished = false;
    });
    _ignorePositionUntil = DateTime.now().add(
      const Duration(milliseconds: 600),
    );
    // Told where the playhead is going before the player reports getting there,
    // so the jump is never mistaken for having played through the markers in
    // between.
    widget.markers?.syncTo(clamped);
    _adapter.seekTo(clamped);
  }

  /// The point in the video a bar fraction stands for.
  Duration _atFraction(double fraction) =>
      Duration(milliseconds: (fraction * _duration.inMilliseconds).round());

  /// Makes sure there is a preview for the stream now playing.
  ///
  /// Rebuilt when the URL changes — a quality switch hands back a different
  /// stream, and frames cached from the old one are the wrong pixels.
  void _ensurePreview() {
    final url = _adapter.previewSourceUrl;
    // Nothing to read: a source that plays through a WebView or a DRM pipeline
    // never exposes a stream. The bubble shows its timestamp alone.
    if (url == null || _duration <= Duration.zero) {
      if (url == null) {
        debugPrint(
          'ScrubPreview: this source exposes no readable URL, so there are no '
          'frames to pull; the scrubber will show timestamps only.',
        );
      }
      return;
    }
    if (_preview?.videoUrl == url) return;
    _preview?.dispose();
    _preview = ScrubPreview(
      videoUrl: url,
      duration: _duration,
      headers: _adapter.previewHeaders,
    );
    debugPrint('ScrubPreview: reading frames from $url');
  }

  /// Moves the picture to where the finger is, mid-drag.
  ///
  /// Throttled, because a drag reports every few pixels and a seek per report
  /// is more than the player can service — the requests queue and the picture
  /// ends up trailing the finger by seconds. The final position is never lost
  /// to the throttle: releasing seeks unconditionally.
  void _scrubSeek(double fraction, {bool force = false}) {
    if (!_caps.seek || _duration <= Duration.zero) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastScrubSeek) < _scrubSeekInterval) return;
    _lastScrubSeek = now;
    _adapter.seekTo(_atFraction(fraction));
  }

  /// Begins a scrub: pause, and jump to where the finger went down.
  ///
  /// Playback is paused for the duration of the drag so each position seeked
  /// to can actually be seen. Letting it run would have the video playing on
  /// from every landing point, fighting the drag.
  void _onScrubStart(double fraction) {
    _hideTimer?.cancel();
    _ensurePreview();
    // Dragging over a marker is not playing through it, so no cue is raised
    // until the finger lifts.
    widget.markers?.hold(CueHold.scrub);
    // The user has taken over, so a settle probe still running from a speed or
    // quality change must not re-assert play over this pause. See [_holdPlaying].
    _playbackCommand++;
    _resumeAfterScrub = _playing;
    if (_playing) _adapter.pause();

    setState(() {
      _dragging = true;
      _dragFraction = fraction;
    });
    _preview?.request(_atFraction(fraction));
    _scrubSeek(fraction, force: true);
  }

  void _onScrubUpdate(double fraction) {
    setState(() => _dragFraction = fraction);
    _preview?.request(_atFraction(fraction));
    _scrubSeek(fraction);
  }

  /// Commits the scrub, and resumes if the video had been playing.
  void _onScrubEnd() {
    if (!_dragging) return;
    final target = _atFraction(_dragFraction);
    setState(() => _dragging = false);
    // Ahead of releasing the cues, so the seek this commits is the position
    // they are armed from.
    _seekTo(target);
    widget.markers?.release(CueHold.scrub);

    if (_resumeAfterScrub) {
      _resumeAfterScrub = false;
      _playbackCommand++;
      _adapter.play();
    }
    _restartHideTimer();
  }

  void _onDoubleTapSeek(bool forward) {
    if (!_caps.seek) return;
    _seekTo(_position + (forward ? _seekStep : -_seekStep));

    // The controls come down for the gesture instead of waiting out the delay.
    // A double tap is about the picture — the seek indicator is drawn straight
    // onto it — so the bars and buttons get out of the way of the frames being
    // jumped to, and stay out until the surface is tapped again.
    _hideTimer?.cancel();

    setState(() {
      _controlsVisible = false;
      if (_seekFeedbackForward != forward) _seekFeedbackSeconds = 0;
      _seekFeedbackForward = forward;
      _seekFeedbackSeconds += _seekStep.inSeconds;
    });
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFeedbackSeconds = 0);
    });
  }

  void _togglePlayPause() {
    _playbackCommand++;
    if (_finished) {
      setState(() {
        _finished = false;
        _position = Duration.zero;
      });
      _adapter.replay();
    } else if (_playing) {
      _adapter.pause();
    } else {
      _adapter.play();
    }
    _showControls();
  }

  void _toggleMute() {
    _adapter.setMuted(!_muted);
    setState(() => _muted = !_muted);
    _showControls();
  }

  /// Puts the settings sheet up over the whole screen.
  ///
  /// A modal route on the *root* navigator, so it clears the player box — and
  /// in fullscreen it lands inside [FullscreenRotation], which wraps the app
  /// above its navigator, so it comes up the same way round as the video.
  Future<void> _openSettings() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    // An action like any other: it puts the delay back to full, and the delay
    // then runs its course whether or not the sheet is still up.
    _showControls();

    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      // The sheet paints its own surface, corners and safe area, so the route
      // supplies only the barrier.
      backgroundColor: Colors.transparent,
      elevation: 0,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      // Frees the sheet from the default half-screen ceiling; the ceiling that
      // matters is the one inside, which is a share of the screen.
      isScrollControlled: true,
      // Fullscreen turns the app sideways, where a sheet spanning the long edge
      // would be a very wide, very short strip. Capped so it stays a sheet.
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheetContext) {
        _sheetContext = sheetContext;
        return _SettingsSheet(
          pageBuilder: (page, goTo, refresh) => switch (page) {
            _SheetPage.root => _buildSettingsPage(goTo),
            _SheetPage.speed => _buildSpeedPage(refresh),
            _SheetPage.quality => _buildQualityPage(),
          },
        );
      },
    );

    _sheetContext = null;
    _sheetOpen = false;
    if (!mounted) return;
    // The delay starts again from here, but the controls are left however the
    // sheet found them. Deliberately not [_showControls]: the delay has been
    // running the whole time the sheet was up, so by the time an option is
    // picked they have usually already timed out — and putting them back on
    // screen would mean changing the speed or the quality summoned a control
    // layer the user had watched go away.
    _restartHideTimer();
  }

  /// Dismisses the sheet, if one is up. Safe to call when none is.
  void _closeSheet() {
    final sheetContext = _sheetContext;
    if (sheetContext == null || !sheetContext.mounted) return;
    _sheetContext = null;
    Navigator.of(sheetContext).pop();
  }

  // ------------------------------------------------------------------- quality

  /// The renditions this source can actually be switched between.
  ///
  /// Empty for anything with nothing to choose from — a plain .mp4 is one file,
  /// and some platforms hand back a single muxed stream — which is what leaves
  /// the row inert.
  List<VideoQuality> get _qualities {
    if (!_caps.quality) return const [];
    final available = _adapter.availableQualities;
    return available.length > 1 ? available : const [];
  }

  bool get _canSwitchQuality =>
      _qualities.isNotEmpty && _adapter.currentQuality != null;

  /// What the quality row reads.
  ///
  /// A dash when the backend reports nothing, so the row still says something
  /// rather than showing a blank.
  String get _qualityLabel => _adapter.currentQuality?.label ?? '—';

  Future<void> _setQuality(VideoQuality quality) async {
    final command = ++_playbackCommand;
    final wasPlaying = _playing;

    _closeSheet();
    _setSwitching(true);
    try {
      await _adapter.setQuality(quality);
      // The swap ends in the same play() that a speed change does, so it can
      // strand playback the same way. See [_holdPlaying].
      if (wasPlaying) await _holdPlaying(command);
    } finally {
      // Normally already cleared, the moment playback resumes — see
      // [_onAdapterChanged]. This is the backstop for a swap that never
      // gets there, so the spinner cannot be left running for good.
      // Only if this is still the live switch. Picking another quality bumps
      // [_playbackCommand], which ends the previous call's [_holdPlaying]
      // early — and without this guard that older call's finally would clear
      // the flag belonging to the swap now in flight, taking the spinner off
      // mid-switch and leaving a play button over a frozen frame.
      if (mounted && command == _playbackCommand) _setSwitching(false);
    }
  }

  static String _speedLabel(double rate) => rate == rate.roundToDouble()
      ? '${rate.toStringAsFixed(0)}x'
      : '${rate.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}x';

  Future<void> _setPlaybackRate(double rate) async {
    if (!_caps.playbackSpeed) return;
    final command = ++_playbackCommand;
    final wasPlaying = _playing;

    // The sheet deliberately stays up: picking a speed is something the user
    // may want to do two or three times over, comparing as they go, and
    // dismissing on the first pick would make them reopen it to try the next.
    // Tapping outside is how they leave. [_setQuality] still closes on pick —
    // a quality swap tears the stream down and puts a spinner over the video,
    // which is worth getting out of the way for.
    setState(() => _playbackRate = rate);

    // Held only across the change itself, not across the recovery window that
    // follows it: the window runs for seconds, and a cue swallowed for that
    // long is a cue the user never sees. [_holdPlaying] yields to a cue instead.
    widget.markers?.hold(CueHold.transition);
    try {
      await _adapter.setPlaybackSpeed(rate);
    } finally {
      widget.markers?.release(CueHold.transition);
    }
    if (wasPlaying) await _holdPlaying(command);
  }

  /// Keeps playback alive across a speed change.
  ///
  /// Raising the speed after a spell at a slow one makes the audio track
  /// re-buffer, and the package's audio/video sync engine reacts to a
  /// buffering audio track by pausing the video. Its own 200ms timer then
  /// stops, because it only runs while the video is playing — so it never sees
  /// the buffer fill and the video stays paused for good. That is the stall:
  /// 1x → 0.25x → wait → 1.25x reproduces it every time.
  ///
  /// Nothing inside the package recovers from it, so playback is re-asserted
  /// here. `play()` waits for both buffers before starting, so a call landing
  /// mid-buffer is not wasted, and it restarts the sync timer.
  ///
  /// The whole window is watched rather than exiting on the first healthy
  /// reading: the stall usually arrives a beat *after* the change, so an early
  /// "still playing" means nothing. A bump to [_playbackCommand] — the user
  /// pressing pause — ends it immediately, so their pause is never undone.
  Future<void> _holdPlaying(int command) async {
    // Off unless the backend asks for it. A well-behaved player recovers on its
    // own, and re-asserting playback it never lost is at best pointless.
    if (!_adapter.reassertsPlaybackAfterRateChange) return;
    var deadline = DateTime.now().add(_speedRecoveryWindow);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_speedRecoveryInterval);
      if (!mounted || command != _playbackCommand) return;
      if (_adapter.isDisposed || _adapter.isFinished) return;

      // A cue overlay is paused deliberately, and that pause is not the stall
      // this is here to recover from — re-asserting playback under one plays
      // the video behind the panel and hands the cue back a video already
      // running when it dismisses. The window is pushed back instead of spent,
      // so the watch resumes at full length once the overlay has gone.
      if (widget.markers?.active != null) {
        deadline = DateTime.now().add(_speedRecoveryWindow);
        continue;
      }

      if (!_adapter.isPlaying) {
        // A stall inside the recovery window is still the player working, not
        // the user having paused, so keep showing the spinner. Without this a
        // drop-out after the first resume puts a play button back on screen
        // mid-recovery, which is the "paused again, then a loader" case.
        _setSwitching(true);
        // Deliberately not awaited. play() waits on the audio buffer
        // internally, and that is precisely the buffer that is stuck —
        // awaiting it parks the loop on its first iteration and no retry ever
        // happens. Measured: with the await, the stall persisted in every run;
        // without it, every run recovered on the next tick.
        unawaited(_adapter.play());
      }
    }
  }

  void _onBackPressed() {
    if (widget.isFullscreen) {
      widget.onToggleFullscreen(keepControls: true);
    } else {
      widget.onBack?.call();
    }
  }

  void _onVerticalSwipe(DragEndDetails details) {
    if (!_caps.fullscreen) return;
    final wantsFullscreen = fullscreenIntentFromSwipe(details);
    if (wantsFullscreen == null) return;
    // Nothing was pressed — the swipe is made on the picture, usually with the
    // controls not even up — so the video it lands in stays as bare.
    if (wantsFullscreen != widget.isFullscreen) {
      widget.onToggleFullscreen(keepControls: false);
    }
  }

  /// Applies display cutout insets, but only in fullscreen.
  ///
  /// Inline, the player is a box part-way down a page, so the screen's insets
  /// have nothing to do with it — applying them would push the top bar down by
  /// the status bar height and lift the bottom bar off the player's edge.
  Widget _insets({
    required Widget child,
    bool top = false,
    bool bottom = false,
  }) {
    if (!widget.isFullscreen) return child;
    return SafeArea(top: top, bottom: bottom, child: child);
  }

  // --------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final hasDuration = _duration > Duration.zero;
    final displayed = _dragging && hasDuration
        ? Duration(
            milliseconds: (_dragFraction * _duration.inMilliseconds).round(),
          )
        : _position;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildGestureLayer(),
          if (_seekFeedbackSeconds > 0) _buildSeekFeedback(),
          // Not while scrubbing. Every seek the drag fires puts the player
          // briefly into buffering, so the spinner and the play button it
          // replaces would swap back and forth across the middle of the
          // picture for the whole drag. Nor under a cue: the video is stopped
          // on purpose there, and a spinner turning through the scrim reads as
          // the player having hung.
          if (_busy && !_dragging && _marker == null)
            Center(
              child: SizedBox(
                width: 42,
                height: 42,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: widget.accentColor,
                ),
              ),
            ),
          // A chooser replaces the controls rather than covering them: the top
          // bar and the play button showing through behind the chips reads as
          // two competing layers, and the buttons underneath are unreachable
          // anyway while the panel's scrim is swallowing taps.
          AnimatedOpacity(
            opacity: _showControlLayer ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: !_showControlLayer,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IgnorePointer(child: _Scrim(bottomOnly: _dragging)),
                  _buildTopBar(),
                  _buildCenterControls(_busy),
                  _buildBottomBar(displayed, hasDuration),
                ],
              ),
            ),
          ),
          // Over the controls: the cue interrupts whatever the user was doing.
          // Under the error, which stops everything. The settings sheet is not
          // in this stack at all — it is a route above the whole screen, and a
          // cue closes it on the way up.
          if (_marker != null)
            MarkerOverlay(
              key: ValueKey(_marker),
              marker: _marker!,
              remaining: widget.markers?.remaining,
              accentColor: widget.accentColor,
              onSkip: () => widget.markers?.dismiss(),
            ),
          if (_adapter.hasError) _buildError(),
        ],
      ),
    );
  }

  /// The full-surface gesture layer. Sits below the controls, so buttons and
  /// the scrubber win the hit test and everything else falls through to here.
  Widget _buildGestureLayer() {
    Widget zone({required bool forward}) {
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onSurfaceTap,
          onDoubleTap: () => _onDoubleTapSeek(forward),
          onVerticalDragEnd: _onVerticalSwipe,
          child: const SizedBox.expand(),
        ),
      );
    }

    return Row(children: [zone(forward: false), zone(forward: true)]);
  }

  Widget _buildSeekFeedback() {
    return IgnorePointer(
      child: Align(
        alignment: _seekFeedbackForward
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(40),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _seekFeedbackForward
                        ? Icons.fast_forward_rounded
                        : Icons.fast_rewind_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$_seekFeedbackSeconds s',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Takes [child] out of the way for the duration of a scrub.
  ///
  /// A scrub is about the picture — the video is seeking under the finger —
  /// so everything but the bar and its readout gets out of the light. Faded
  /// rather than removed, so nothing around it changes size and the bar cannot
  /// shift under the finger holding it.
  Widget _hideWhileScrubbing(Widget child) {
    return AnimatedOpacity(
      opacity: _dragging ? 0 : 1,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      child: IgnorePointer(ignoring: _dragging, child: child),
    );
  }

  Widget _buildTopBar() {
    final title = widget.title ?? '';
    final showBack = widget.isFullscreen || widget.onBack != null;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _hideWhileScrubbing(
        _insets(
          top: true,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.isFullscreen ? 12 : 4,
              vertical: 4,
            ),
            child: Row(
              children: [
                if (showBack)
                  _ControlButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back',
                    onPressed: _onBackPressed,
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: showBack ? 0 : 12),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: widget.isFullscreen ? 16 : 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                _ControlButton(
                  icon: Icons.settings_rounded,
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterControls(bool isBuffering) {
    return _hideWhileScrubbing(
      Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_caps.seek) ...[
              _ControlButton(
                icon: Icons.replay_10_rounded,
                iconSize: 34,
                filled: true,
                tooltip: 'Back 10 seconds',
                onPressed: () {
                  _seekTo(_position - _seekStep);
                  _showControls();
                },
              ),
              const SizedBox(width: 20),
            ],
            // Placeholder keeps the layout stable while the spinner shows.
            SizedBox.square(
              dimension: 64,
              child: isBuffering
                  ? null
                  : _PlayPauseButton(
                      playing: _playing,
                      finished: _finished,
                      accentColor: widget.accentColor,
                      onPressed: _togglePlayPause,
                    ),
            ),
            if (_caps.seek) ...[
              const SizedBox(width: 20),
              _ControlButton(
                icon: Icons.forward_10_rounded,
                iconSize: 34,
                filled: true,
                tooltip: 'Forward 10 seconds',
                onPressed: () {
                  _seekTo(_position + _seekStep);
                  _showControls();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(Duration displayed, bool hasDuration) {
    final fraction = hasDuration
        ? (_dragging
              ? _dragFraction
              : _position.inMilliseconds / _duration.inMilliseconds)
        : 0.0;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _insets(
        bottom: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            widget.isFullscreen ? 20 : 12,
            0,
            widget.isFullscreen ? 20 : 12,
            widget.isFullscreen ? 12 : 4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              VideoProgressBar(
                value: fraction,
                buffered: _buffered,
                accentColor: widget.accentColor,
                isDragging: _dragging,
                enabled: hasDuration && _caps.seek,
                scrubLabel: hasDuration ? formatDuration(displayed) : null,
                scrubFrame: _preview?.frame,
                markers: _markerFractions,
                onSeekStart: _onScrubStart,
                onSeekUpdate: _onScrubUpdate,
                onSeekEnd: _onScrubEnd,
              ),
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Text(
                      '${formatDuration(displayed)}'
                      ' / '
                      '${hasDuration ? formatDuration(_duration) : '--:--'}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  // Faded, not dropped: these are the tallest things in the
                  // row, so removing them would shrink it and slide the bar
                  // down out from under the finger holding it.
                  if (_caps.mute)
                    _hideWhileScrubbing(
                      _ControlButton(
                        icon: _muted
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        iconSize: 20,
                        tooltip: _muted ? 'Unmute' : 'Mute',
                        onPressed: _toggleMute,
                      ),
                    ),
                  const Spacer(),
                  if (_caps.fullscreen)
                    _hideWhileScrubbing(
                      _ControlButton(
                        icon: widget.isFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        iconSize: 28,
                        tooltip: widget.isFullscreen
                            ? 'Exit fullscreen'
                            : 'Fullscreen',
                        // No _showControls() to go with it: the move throws
                        // these controls away, and `keepControls` is what the
                        // copy replacing them mounts with.
                        onPressed: () =>
                            widget.onToggleFullscreen(keepControls: true),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The sheet's front page: what can be changed, and what it is set to now.
  ///
  /// Speed and quality live in one sheet because they are one question — how
  /// this video plays — and a bar with a chip for each was two readouts
  /// competing for the little room the bottom row has.
  Widget _buildSettingsPage(ValueChanged<_SheetPage> goTo) {
    return Column(
      key: const ValueKey(_SheetPage.root),
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SheetHeader(title: 'Settings'),
        // Dropped entirely rather than dimmed: unlike quality, a speed the
        // source cannot change has no reading worth showing — it is always 1x.
        if (_caps.playbackSpeed)
          _SheetRow(
            icon: Icons.speed_rounded,
            label: 'Playback speed',
            value: _speedLabel(_playbackRate),
            onTap: () => goTo(_SheetPage.speed),
          ),
        _SheetRow(
          icon: Icons.high_quality_rounded,
          label: 'Quality',
          // The label still says what the video is even when there is nothing
          // to switch to — it just cannot be tapped.
          value: _canSwitchQuality ? _qualityLabel : '$_qualityLabel · only',
          enabled: _canSwitchQuality,
          onTap: () => goTo(_SheetPage.quality),
        ),
      ],
    );
  }

  Widget _buildSpeedPage(VoidCallback refresh) {
    return Column(
      key: const ValueKey(_SheetPage.speed),
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SheetHeader(title: 'Playback speed'),
        for (final speed in _speeds)
          _SheetOption(
            label: _speedLabel(speed),
            selected: (speed - _playbackRate).abs() < 0.01,
            accentColor: widget.accentColor,
            // The page stays up, so it has to redraw itself for the tick to
            // move. A `setState` here would not reach it — the sheet is a route
            // of its own. [_setPlaybackRate] assigns the new rate before its
            // first await, so this reads the fresh one.
            onTap: () {
              _setPlaybackRate(speed);
              refresh();
            },
          ),
      ],
    );
  }

  Widget _buildQualityPage() {
    return Column(
      key: const ValueKey(_SheetPage.quality),
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SheetHeader(title: 'Quality'),
        for (final quality in _qualities)
          _SheetOption(
            label: quality.label,
            selected: quality == _adapter.currentQuality,
            accentColor: widget.accentColor,
            onTap: () => _setQuality(quality),
          ),
      ],
    );
  }

  Widget _buildError() {
    return const Positioned.fill(
      child: ColoredBox(
        color: Colors.black87,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: Colors.white70,
                  size: 32,
                ),
                SizedBox(height: 8),
                Text(
                  'Something went wrong while loading this video.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Top and bottom gradient scrims that keep the controls legible.
class _Scrim extends StatelessWidget {
  const _Scrim({this.bottomOnly = false});

  /// Drops the top and middle of the wash, leaving only enough at the bottom
  /// to keep the readout legible. For scrubbing, where the video is the thing
  /// being looked at and dimming it defeats the point.
  final bool bottomOnly;

  @override
  Widget build(BuildContext context) {
    final clear = Colors.black.withValues(alpha: 0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            bottomOnly ? clear : Colors.black.withValues(alpha: 0.65),
            bottomOnly ? clear : Colors.black.withValues(alpha: 0.15),
            bottomOnly ? clear : Colors.black.withValues(alpha: 0.15),
            Colors.black.withValues(alpha: bottomOnly ? 0.6 : 0.75),
          ],
          stops: const [0, 0.3, 0.65, 1],
        ),
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.playing,
    required this.finished,
    required this.accentColor,
    required this.onPressed,
  });

  final bool playing;
  final bool finished;
  final Color accentColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final icon = finished
        ? Icons.replay_rounded
        : playing
        ? Icons.pause_rounded
        : Icons.play_arrow_rounded;

    return GestureDetector(
      onTap: onPressed,
      child: Container(
        decoration: BoxDecoration(color: accentColor, shape: BoxShape.circle),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: Icon(icon, key: ValueKey(icon), color: Colors.white, size: 38),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 22,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final double iconSize;

  /// Backs the icon with a solid disc, for buttons that sit over open picture
  /// rather than over a scrim.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: iconSize,
      color: Colors.white,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      style: IconButton.styleFrom(
        // A flat disc, never a blurred shadow. Blur over the player's platform
        // view is composited into a separate overlay on Android, where it comes
        // out as a hard dark halo instead of a soft falloff — reading as a
        // smudge sitting behind the icon.
        backgroundColor: filled ? Colors.black.withValues(alpha: 0.3) : null,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon),
    );
  }
}

/// Which page the settings sheet is showing.
///
/// [root] is the front page — the list of things that can be changed. The other
/// two are the option lists it leads to.
enum _SheetPage { root, speed, quality }

/// The body of the settings sheet, and the only owner of which page it shows.
///
/// The route it is pushed in owns the barrier, the slide-up and the drag to
/// dismiss; this owns the surface, what is on it, and the stepping between its
/// pages. Deliberately not driven from [_PlayerControlsState]: the sheet
/// outlives nothing but its own route, and state held out there would have to
/// survive being torn down while a route still listened to it.
///
/// Swapping the page resizes the sheet in place, so stepping from the front
/// page into an option list reads as one surface growing rather than a second
/// sheet arriving.
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.pageBuilder});

  /// Builds [page]'s contents. `goTo` steps the sheet to another page;
  /// `refresh` redraws the one it is on, for a page that changes something and
  /// stays up to show it.
  final Widget Function(
    _SheetPage page,
    ValueChanged<_SheetPage> goTo,
    VoidCallback refresh,
  )
  pageBuilder;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  /// Share of the screen the sheet may grow to before its contents scroll.
  ///
  /// Bounded at all, because a route sheet is otherwise free to run to the top
  /// of the screen — and in fullscreen the screen is landscape, where the eight
  /// speeds are taller than it is.
  static const double _maxScreenFraction = 0.7;

  _SheetPage _page = _SheetPage.root;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * _maxScreenFraction;
    final child = widget.pageBuilder(
      _page,
      (page) => setState(() => _page = page),
      () => setState(() {}),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      // A Material of its own, not just a coloured box: the rows are InkWells,
      // and ink is painted on the nearest Material — which without this would
      // be one somewhere under the route, leaving every splash invisible.
      child: Material(
        color: const Color(0xF21C1C1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          // The sheet sits on the true bottom of the screen now, so the home
          // indicator is its problem. Not the top: the sheet never reaches it.
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Flexible(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: SingleChildScrollView(child: child),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A sheet page's title, with a back arrow on the pages that have somewhere to
/// go back to.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// A row on the sheet's front page: what it is, and what it is set to.
///
/// Dimmed and inert when [enabled] is false — the value still says what the
/// video is, it just cannot be changed.
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.white : Colors.white38;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: enabled ? Colors.white70 : Colors.white30,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (enabled)
              const Icon(
                Icons.chevron_right_rounded,
                color: Colors.white54,
                size: 20,
              )
            else
              const SizedBox(width: 20),
          ],
        ),
      ),
    );
  }
}

/// One choice inside an option list, ticked when it is the current one.
class _SheetOption extends StatelessWidget {
  const _SheetOption({
    required this.label,
    required this.selected,
    required this.accentColor,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            // Held even when unticked, so the labels line up down the list
            // instead of stepping sideways at the current one.
            SizedBox.square(
              dimension: 20,
              child: selected
                  ? Icon(Icons.check_rounded, color: accentColor, size: 20)
                  : null,
            ),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
