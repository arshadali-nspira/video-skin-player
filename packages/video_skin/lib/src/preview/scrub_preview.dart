import 'package:flutter/foundation.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus.dart';

/// Pulls a single frame out of [video] at [at]. Returns null if there is none
/// to be had.
typedef FrameExtractor =
    Future<Uint8List?> Function(
      String video,
      Duration at,
      Map<String, String>? headers,
    );

/// Supplies the still frames shown above the scrubber while seeking.
///
/// Frames come from the platform's own extractor — `AVAssetImageGenerator` on
/// iOS, `MediaMetadataRetriever` on Android — reading the same URL the player
/// is playing. Every frame costs a decode and a seek, far too slow to run once
/// per drag update, so this does three things to keep a scrub smooth:
///
///  * requests snap to a coarse grid ([_stepFor]), so a drag across the bar
///    asks for a few dozen frames rather than one per pixel;
///  * one extraction runs at a time, and while it does, only the *latest*
///    position asked for is kept — everything the finger passed over in
///    between is dropped;
///  * what has been pulled is kept, so scrubbing back over a stretch is free.
///
/// [frame] holds the most recent frame decoded rather than being cleared on
/// every request: a stale frame for a moment reads better than a hole opening
/// in the bubble each time the finger moves.
///
/// Not every source can be read this way — a platform without the plugin, or a
/// stream the extractor is refused access to. Rather than hammering a source
/// that cannot work, this gives up after [_failureLimit] consecutive failures
/// and leaves [frame] empty for good, which shows the bubble's timestamp on its
/// own.
class ScrubPreview {
  ScrubPreview({
    required this.videoUrl,
    required Duration duration,
    this.headers,
    FrameExtractor? extractor,
  }) : _step = _stepFor(duration),
       _extractor = extractor ?? _platformExtractor;

  /// Where frames come from. Swapped in tests, which have no platform channel
  /// to answer — and no video to read either.
  final FrameExtractor _extractor;

  /// The video to read frames from. Same URL the player resolved.
  final String videoUrl;

  /// Sent with the request, for a source that will not serve a bare GET.
  final Map<String, String>? headers;

  /// The spacing of the grid requests are snapped to.
  final Duration _step;

  /// The most recently decoded frame, or null before the first one lands.
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  /// Wide enough to look sharp at the size the bubble draws it, small enough
  /// to decode quickly. The extractor keeps the video's own aspect ratio.
  static const int _frameWidth = 160;

  /// Roughly a screenful of scrubbing each way before anything is evicted.
  static const int _cacheLimit = 48;

  static const int _failureLimit = 3;

  /// Insertion-ordered, so the oldest entry is the one that goes.
  final Map<int, Uint8List> _cache = <int, Uint8List>{};

  /// The grid slot waiting to be decoded, if any. Overwritten, not queued —
  /// only the position the finger is on now is worth decoding.
  int? _pending;

  bool _working = false;
  int _failures = 0;
  bool _unavailable = false;
  bool _disposed = false;

  /// Whether frames have been given up on for this source.
  bool get unavailable => _unavailable;

  /// How far apart to pull frames for a video of [duration].
  ///
  /// A fraction of the whole rather than a fixed interval, so a three-minute
  /// clip and a two-hour film both cost about the same number of decodes.
  /// Bounded at both ends: closer than two seconds is more decoding than a
  /// drag can keep up with, further than ten and the preview stops tracking
  /// the finger.
  static Duration _stepFor(Duration duration) {
    if (duration <= Duration.zero) return const Duration(seconds: 5);
    final step = duration.inMilliseconds ~/ 120;
    return Duration(milliseconds: step.clamp(2000, 10000));
  }

  /// Asks for the frame at [position].
  ///
  /// Returns at once. A frame already held is published immediately;
  /// otherwise one is decoded and [frame] updates when it arrives.
  void request(Duration position) {
    if (_disposed || _unavailable) return;

    final slot = position.inMilliseconds ~/ _step.inMilliseconds;
    final cached = _cache[slot];
    if (cached != null) {
      frame.value = cached;
      return;
    }

    _pending = slot;
    _pump();
  }

  Future<void> _pump() async {
    if (_working) return;
    _working = true;
    try {
      while (!_disposed && _pending != null) {
        final slot = _pending!;
        _pending = null;

        final bytes = await _extract(slot);
        if (_disposed) return;

        if (bytes == null) {
          if (++_failures >= _failureLimit) {
            debugPrint(
              'ScrubPreview: giving up on $videoUrl after $_failures failures; '
              'the scrubber will show timestamps only.',
            );
            _unavailable = true;
            _pending = null;
            frame.value = null;
            return;
          }
          continue;
        }

        _failures = 0;
        _store(slot, bytes);
        frame.value = bytes;
      }
    } finally {
      _working = false;
    }
  }

  Future<Uint8List?> _extract(int slot) async {
    try {
      return await _extractor(
        videoUrl,
        Duration(milliseconds: slot * _step.inMilliseconds),
        headers,
      );
      // Anything the platform side throws — an unimplemented channel, a source
      // it will not open — is a source without previews, not a crash. Reported
      // though: silence here is indistinguishable from the feature simply not
      // working, and the platform's message is the only clue as to which
      // sources a device will and will not read.
    } catch (error) {
      debugPrint('ScrubPreview: no frame at slot $slot of $videoUrl — $error');
      return null;
    }
  }

  static Future<Uint8List?> _platformExtractor(
    String video,
    Duration at,
    Map<String, String>? headers,
  ) {
    return VideoThumbnailPlus.thumbnailData(
      video: video,
      headers: headers,
      // JPEG over PNG: a preview this small gains nothing from lossless, and
      // the encode is a slice of every frame's cost.
      imageFormat: ImageFormat.JPEG,
      maxWidth: _frameWidth,
      quality: 55,
      timeMs: at.inMilliseconds,
    );
  }

  void _store(int slot, Uint8List bytes) {
    _cache[slot] = bytes;
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    _cache.clear();
    frame.dispose();
  }
}
