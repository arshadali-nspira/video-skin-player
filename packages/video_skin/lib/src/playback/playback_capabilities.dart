import 'package:flutter/foundation.dart';

/// What a backend can actually do, so the skin can leave out what it cannot.
///
/// Read on every build rather than once — several of these are only knowable
/// after the source has resolved. A capability that is off does not disable a
/// control so much as remove it: the seek bar goes inert, the quality row is
/// dimmed to a readout, the speed row disappears.
@immutable
class PlaybackCapabilities {
  const PlaybackCapabilities({
    this.seek = true,
    this.playbackSpeed = true,
    this.quality = true,
    this.mute = true,
    this.fullscreen = true,
  });

  /// Everything off. A useful base for a backend that turns capabilities on as
  /// its source resolves.
  static const none = PlaybackCapabilities(
    seek: false,
    playbackSpeed: false,
    quality: false,
    mute: false,
    fullscreen: false,
  );

  /// Whether the playhead can be moved. Off disables the scrubber, the ±10s
  /// buttons and the double-tap seek — a live stream, or a source the platform
  /// cannot seek without stalling.
  final bool seek;

  /// Whether [VideoPlaybackAdapter.setPlaybackSpeed] does anything.
  final bool playbackSpeed;

  /// Whether renditions can be switched between. The quality row still shows
  /// what is playing when this is off; it just cannot be tapped.
  final bool quality;

  /// Whether the audio can be muted.
  final bool mute;

  /// Whether the fullscreen button and the vertical swipe are offered.
  final bool fullscreen;

  PlaybackCapabilities copyWith({
    bool? seek,
    bool? playbackSpeed,
    bool? quality,
    bool? mute,
    bool? fullscreen,
  }) {
    return PlaybackCapabilities(
      seek: seek ?? this.seek,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      quality: quality ?? this.quality,
      mute: mute ?? this.mute,
      fullscreen: fullscreen ?? this.fullscreen,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackCapabilities &&
      other.seek == seek &&
      other.playbackSpeed == playbackSpeed &&
      other.quality == quality &&
      other.mute == mute &&
      other.fullscreen == fullscreen;

  @override
  int get hashCode =>
      Object.hash(seek, playbackSpeed, quality, mute, fullscreen);
}
