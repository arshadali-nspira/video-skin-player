import 'dart:async';

import 'package:flutter/widgets.dart';

import '../playback/playback_adapter.dart';

/// A point in a video that shows an overlay when playback reaches it.
///
/// Drawn as a tick on the progress bar, so the points are visible before they
/// arrive. When the playhead crosses one the video pauses, the overlay comes
/// up for [duration], and playback picks itself back up — see
/// [VideoMarkerController].
@immutable
class VideoMarker {
  const VideoMarker({
    required this.time,
    required this.title,
    this.body,
    this.duration = const Duration(seconds: 5),
    this.builder,
  });

  /// Where in the video this sits. A marker past the end is simply never
  /// reached, and is left off the progress bar.
  final Duration time;

  final String title;

  /// Supporting line under the title. Optional — some cues are a heading only.
  final String? body;

  /// How long the overlay stays up before it dismisses itself.
  final Duration duration;

  /// Draws the overlay's content in place of [title] and [body].
  ///
  /// The scrim, the countdown and the skip button are still the overlay's; this
  /// only replaces what sits between them.
  final WidgetBuilder? builder;
}

/// A reason cues cannot be raised for the moment.
///
/// Held rather than cleared: the marker is left armed and the playhead keeps
/// being tracked, so nothing fires from a position that is moving for a reason
/// other than the video playing.
enum CueHold {
  /// A finger is dragging the playhead over the bar. Passing a marker is not
  /// playing through it.
  scrub,

  /// A speed or quality change is in flight.
  ///
  /// A quality swap tears the stream down and builds it again: the position
  /// drops to zero and climbs back to where it was. Read as playback that is a
  /// rewind followed by a fast-forward — which would arm every marker in the
  /// video and then raise whichever one the restore lands on.
  transition,
}

/// Watches playback and raises each [VideoMarker] as it is reached.
///
/// Lives with the player rather than with the controls, because the controls
/// are torn down and rebuilt on the way into fullscreen — state kept there
/// would forget which markers had already been shown and raise them a second
/// time on the far side of the transition.
///
/// A marker fires only when the playhead *plays* through it. Seeking is not
/// playing: a jump forward moves the mark behind the playhead without raising
/// it, and a jump backwards re-arms every marker now ahead again, so a rewind
/// plays the same cue over.
class VideoMarkerController extends ChangeNotifier {
  VideoMarkerController({required List<VideoMarker> markers})
    : markers = List.unmodifiable(
        markers.toList()..sort((a, b) => a.time.compareTo(b.time)),
      );

  /// The markers, earliest first.
  final List<VideoMarker> markers;

  /// The largest step between two position reports that can still be playback.
  ///
  /// Anything longer is a seek. The controller reports several times a second,
  /// so even at 2x this is a wide margin.
  static const Duration _maxNaturalStep = Duration(seconds: 2);

  VideoPlaybackAdapter? _player;
  Timer? _timer;

  /// Markers already raised, and so not due again until the playhead goes back
  /// behind them.
  final Set<VideoMarker> _shown = <VideoMarker>{};

  VideoMarker? _active;
  DateTime? _raisedAt;
  bool _resumeOnDismiss = false;
  Duration _lastPosition = Duration.zero;

  /// Why cues are being held back, if they are. A set rather than a flag: a
  /// scrub during a quality swap takes two holds, and the end of either one
  /// must not release the other.
  final Set<CueHold> _holds = <CueHold>{};

  /// The marker whose overlay is up, if any.
  VideoMarker? get active => _active;

  /// How much of the active cue is left to run.
  ///
  /// Read by an overlay as it mounts, so the copy the fullscreen page builds
  /// picks the countdown up where the inline one left it rather than starting
  /// the wait over on screen while the real timer runs out underneath.
  Duration get remaining {
    final marker = _active;
    final raisedAt = _raisedAt;
    if (marker == null || raisedAt == null) return Duration.zero;
    final left = marker.duration - DateTime.now().difference(raisedAt);
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether cues are being held back for any reason.
  bool get isHeld => _holds.isNotEmpty;

  /// Stops cues being raised until [release] is called with the same [reason].
  ///
  /// The position keeps being tracked while held, so whatever the playhead did
  /// meanwhile — dragged over three markers, or torn back to zero and restored
  /// by a quality swap — is simply where it now is, with nothing owed for it.
  void hold(CueHold reason) => _holds.add(reason);

  /// Drops one hold. Cues start again once every reason has been released.
  void release(CueHold reason) {
    if (!_holds.remove(reason) || isHeld) return;
    final player = _player;
    if (player != null) _lastPosition = player.position;
  }

  /// Starts watching [player]. Safe to call again with the same controller.
  void attach(VideoPlaybackAdapter player) {
    if (identical(_player, player)) return;
    _player?.removeListener(_onTick);
    _player = player;
    _lastPosition = player.position;
    player.addListener(_onTick);
  }

  /// Moves the playhead this watches to [position] without playing through the
  /// gap, for a seek the player has been told to make but has yet to report.
  ///
  /// Markers left ahead of the new position are armed again, so seeking back
  /// over one plays its cue a second time.
  void syncTo(Duration position) {
    _lastPosition = position;
    _shown.removeWhere((marker) => marker.time > position);
  }

  void _onTick() {
    final player = _player;
    if (player == null || markers.isEmpty) return;

    final position = player.position;
    // The overlay owns playback until it goes; a hold owns the playhead.
    if (_active != null || isHeld) {
      _lastPosition = position;
      return;
    }

    final previous = _lastPosition;
    _lastPosition = position;

    if (position < previous) {
      // Rewound. Everything now ahead of the playhead is due again.
      _shown.removeWhere((marker) => marker.time > position);
      return;
    }
    // A jump this long is a seek, and a seek passes markers by.
    if (position - previous > _maxNaturalStep) return;

    for (final marker in markers) {
      if (marker.time <= previous || marker.time > position) continue;
      if (!_shown.add(marker)) continue;
      _raise(marker, player);
      return;
    }
  }

  void _raise(VideoMarker marker, VideoPlaybackAdapter player) {
    // Set before pausing: pausing notifies the player's listeners, and this is
    // one of them. Marking the overlay up first keeps that re-entrant tick from
    // being read as ordinary playback.
    _active = marker;
    _raisedAt = DateTime.now();
    _resumeOnDismiss = player.isPlaying;
    if (_resumeOnDismiss) player.pause();

    _timer?.cancel();
    _timer = Timer(marker.duration, dismiss);
    notifyListeners();
  }

  /// Takes the overlay down, resuming playback if the marker interrupted it.
  ///
  /// Called by the timer when the marker's time is up, and by the overlay's own
  /// skip button.
  void dismiss() {
    if (_active == null) return;
    _timer?.cancel();
    _timer = null;
    _active = null;
    _raisedAt = null;

    final player = _player;
    final resume = _resumeOnDismiss;
    _resumeOnDismiss = false;
    if (resume && player != null && !player.isDisposed) {
      _lastPosition = player.position;
      player.play();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _player?.removeListener(_onTick);
    _player = null;
    super.dispose();
  }
}
