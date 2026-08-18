/// Pulls the 11-character video ID out of a YouTube link.
///
/// Replaces `YoutubePlayerController.convertUrlToId`, which left with the
/// `youtube_player_iframe` dependency. `omni_video_player` takes a URL rather
/// than an ID, so this is only used to validate input and to expand a bare ID
/// back into a link.
///
/// Accepts `watch?v=`, `youtu.be/`, `embed/`, `shorts/` and `live/` forms, with
/// or without a scheme, as well as a bare ID. Returns `null` for anything else.
String? youtubeVideoId(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  if (_bareId.hasMatch(trimmed)) return trimmed;

  final uri = Uri.tryParse(
    trimmed.startsWith(RegExp(r'https?://')) ? trimmed : 'https://$trimmed',
  );
  if (uri == null) return null;

  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www|m)\.'), '');
  if (host != 'youtube.com' && host != 'youtu.be' && host != 'youtube-nocookie.com') {
    return null;
  }

  // youtu.be/<id>
  if (host == 'youtu.be') return _validate(uri.pathSegments.firstOrNull);

  // youtube.com/watch?v=<id>
  final query = uri.queryParameters['v'];
  if (query != null) return _validate(query);

  // youtube.com/{embed,shorts,live,v}/<id>
  final segments = uri.pathSegments;
  if (segments.length >= 2 &&
      const {'embed', 'shorts', 'live', 'v'}.contains(segments.first)) {
    return _validate(segments[1]);
  }

  return null;
}

/// Expands a bare video ID into a watch link, and leaves a link alone.
///
/// `omni_video_player` resolves the stream from a URL, so a raw ID has to be
/// turned back into one.
String youtubeWatchUrl(String input) {
  final trimmed = input.trim();
  if (_bareId.hasMatch(trimmed)) {
    return 'https://www.youtube.com/watch?v=$trimmed';
  }
  return trimmed;
}

final RegExp _bareId = RegExp(r'^[\w-]{11}$');

String? _validate(String? candidate) =>
    candidate != null && _bareId.hasMatch(candidate) ? candidate : null;
