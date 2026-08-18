import 'package:flutter/foundation.dart';

/// One selectable rendition of a video, as the skin knows it.
///
/// Backends name their qualities in their own way — an enum, a bitrate, an HLS
/// variant index — so this carries whatever the backend needs to identify the
/// rendition again ([id]) alongside the text the user reads ([label]).
///
/// [height] is what the list is sorted by, highest first. Leave it null for a
/// rendition with no meaningful resolution (an audio-only track, say) and it
/// sorts to the bottom.
@immutable
class VideoQuality {
  const VideoQuality({required this.id, required this.label, this.height});

  /// The backend's own handle for this rendition. Never shown; handed straight
  /// back to [VideoPlaybackAdapter.setQuality].
  final String id;

  /// What the option reads in the settings sheet — `1080p`, `Auto`, `Low`.
  final String label;

  /// Vertical resolution in pixels, if the rendition has one.
  final int? height;

  @override
  bool operator ==(Object other) =>
      other is VideoQuality && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'VideoQuality($id, $label)';
}
