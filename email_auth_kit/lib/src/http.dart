import 'package:http/http.dart' as http;

class PostResponse {
  final int statusCode;
  final String body;
  const PostResponse(this.statusCode, this.body);
}

/// The entire HTTP surface of the package — edge functions AND the
/// Supabase Auth calls — behind one seam. Tests swap [Poster.impl] (or
/// hand a custom impl to `MediasartAuth`) with a scripted double;
/// platform differences stay inside package:http.
abstract class PosterImpl {
  Future<PostResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    required String body,
  });
}

class HttpPoster implements PosterImpl {
  final http.Client _client;
  HttpPoster([http.Client? client]) : _client = client ?? http.Client();

  @override
  Future<PostResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    final request = http.Request(method, url)
      ..headers.addAll(headers)
      ..body = body;
    final res = await _client.send(request);
    return PostResponse(res.statusCode, await res.stream.bytesToString());
  }
}

class Poster {
  static PosterImpl impl = HttpPoster();

  static Future<PostResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) =>
      impl.send(method, url, headers: headers, body: body);
}
