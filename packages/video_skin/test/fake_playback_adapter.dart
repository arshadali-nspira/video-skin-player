import 'package:flutter/widgets.dart';
import 'package:video_skin/video_skin.dart';

/// A stand-in [VideoPlaybackAdapter] for widget tests.
///
/// Holds playback state in plain fields and records the calls made to it, so a
/// test can drive the skin and then assert on what it asked the player to do.
///
/// Also the shortest worked example of an adapter there is: eleven overrides,
/// no player package involved.
class FakePlaybackAdapter extends VideoPlaybackAdapter {
  FakePlaybackAdapter({
    this.duration = const Duration(minutes: 10),
    bool playing = true,
    this.capabilities = const PlaybackCapabilities(),
    this.availableQualities = const [],
    this.currentQuality,
    this.reassertsPlaybackAfterRateChange = true,
    // ignore: prefer_initializing_formals
  }) : _playing = playing;


  @override
  final Duration duration;

  @override
  final PlaybackCapabilities capabilities;

  @override
  final List<VideoQuality> availableQualities;

  @override
  VideoQuality? currentQuality;

  /// On by default, unlike a real adapter: the watch it turns on is behaviour
  /// worth testing, and a fake that left it off would make those tests vacuous.
  @override
  final bool reassertsPlaybackAfterRateChange;

  // ignore: prefer_initializing_formals — the field is private, the parameter is not.
  // ignore: prefer_initializing_formals
  bool _playing;
  Duration _position = Duration.zero;
  bool _buffering = false;
  double _speed = 1;
  bool _muted = false;

  /// Every call made, in order — `play`, `pause`, `seek`, `speed`.
  final List<String> calls = <String>[];

  /// Positions passed to [seekTo], in order.
  final List<Duration> seeks = <Duration>[];

  /// Rates passed to [setPlaybackSpeed], in order.
  final List<double> speeds = <double>[];

  @override
  Duration get position => _position;

  @override
  bool get isPlaying => _playing;

  @override
  bool get isBuffering => _buffering;

  @override
  bool isFinished = false;

  @override
  bool get isMuted => _muted;

  @override
  double get playbackSpeed => _speed;

  @override
  Future<void> play() async {
    calls.add('play');
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seek');
    seeks.add(position);
    _position = position;
    notifyListeners();
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    calls.add('speed');
    speeds.add(speed);
    _speed = speed;
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    notifyListeners();
  }

  @override
  Widget buildFullscreenSurface(BuildContext context) =>
      const SizedBox.expand();

  /// Advances playback the way a running video would, so a test can check
  /// whether the controls are holding their displayed position steady.
  void tick(Duration by) {
    if (!_playing) return;
    _position += by;
    notifyListeners();
  }

  /// Stalls playback the way a real player does while a seek lands: it stops
  /// reporting itself as playing, and reports a buffer instead.
  void stall() {
    _playing = false;
    _buffering = true;
    notifyListeners();
  }
}
