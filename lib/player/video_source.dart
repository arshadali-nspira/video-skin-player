import 'youtube_link.dart';

/// The kinds of input the player knows how to open.
enum VideoSourceKind {
  /// A YouTube link in any of its shapes, or a bare 11-character video ID.
  youtube,

  /// A direct http(s) media URL — an .mp4 file, an .m3u8 HLS playlist, and so
  /// on. Anything the platform's own player can open.
  network,
}

/// Works out how [input] should be played, or `null` if it is not a usable
/// video reference.
///
/// YouTube is checked first, because a YouTube watch page is also a valid
/// http URL and handing it to the network player would try to play the HTML.
VideoSourceKind? classifyVideoInput(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  if (youtubeVideoId(trimmed) != null) return VideoSourceKind.youtube;

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return VideoSourceKind.network;
}
