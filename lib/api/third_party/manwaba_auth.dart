import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/comic.dart' hide Theme;
import '../../models/user_manager.dart';
import '../../utils/app_dio.dart';
import 'manwaba_source.dart';

/// 漫屋吧（manwabb.cc）账号系统对接。
///
/// 站点接口约定（与网页版一致）：
///  - 登录/注册：POST JSON，成功返回 `{code:200, data:{token, userId}}`。
///  - 鉴权：`Authorization: Bearer <token>` 请求头。
///  - 收藏/历史：均为 `/api/user/...` 下的 REST 接口。
class ManwabaAuth {
  ManwabaAuth._();
  static final ManwabaAuth instance = ManwabaAuth._();

  static const userAgent = ManwabaSource.userAgent;

  Dio get _dio => AppDio.create(
        source: 'manwaba_auth',
        enableRateLimit: false,
        options: BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (_) => true,
          headers: {'User-Agent': userAgent},
        ),
      );

  String get _apiBase => ManwabaSource.instance.api;

  Map<String, String> get _authHeaders {
    final token = UserManager().manwabaToken ?? '';
    return {
      'User-Agent': userAgent,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// 从响应中抛出错信息。
  Never _throwFrom(Response res, Map<String, dynamic> data) {
    final msg = (data['msg'] ?? data['message'] ?? data['detail'] ?? '')
        .toString()
        .trim();
    final status = res.statusCode ?? 0;
    if (status == 401) {
      throw '登录已过期，请重新登录';
    }
    throw msg.isNotEmpty ? msg : '请求失败（HTTP $status）';
  }

  // ── 登录 / 注册 ──

  Future<ManwabaLoginResult> login(String username, String password) async {
    final res = await _dio.post(
      '$_apiBase/user/login',
      options: Options(headers: _authHeaders),
      data: {'username': username, 'password': password},
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200 && data['data'] is Map) {
      final d = Map<String, dynamic>.from(data['data'] as Map);
      return ManwabaLoginResult(
        token: '${d['token'] ?? ''}',
        userId: '${d['userId'] ?? ''}',
        username: username,
        nickname: d['nickname']?.toString(),
      );
    }
    _throwFrom(res, data);
  }

  /// 图形验证码：返回图片字节与 captchaId。
  Future<({Uint8List bytes, String captchaId})> fetchCaptcha() async {
    final res = await _dio.get(
      '$_apiBase/user/captcha',
      options: Options(headers: _authHeaders),
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200 && data['data'] is Map) {
      final d = Map<String, dynamic>.from(data['data'] as Map);
      final img = '${d['img'] ?? ''}';
      final captchaId = '${d['captchaId'] ?? ''}';
      Uint8List bytes;
      if (img.startsWith('data:')) {
        final comma = img.indexOf(',');
        final b64 = comma >= 0 ? img.substring(comma + 1) : img;
        bytes = _decodeBase64(b64);
      } else {
        // 验证码是一个 URL，拉取图片字节。
        final imgRes = await _dio.get<List<int>>(
          img.startsWith('http') ? img : 'https://${ManwabaSource.instance.currentApiHost}$img',
          options: Options(
            responseType: ResponseType.bytes,
            headers: {'User-Agent': userAgent},
          ),
        );
        bytes = Uint8List.fromList(imgRes.data ?? const []);
      }
      return (bytes: bytes, captchaId: captchaId);
    }
    _throwFrom(res, data);
  }

  Uint8List _decodeBase64(String b64) {
    // 简单 base64 解码，避免引入额外依赖。
    const lookup =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final clean = b64.replaceAll(RegExp(r'\s'), '');
    final padding = clean.endsWith('=') ? (clean.endsWith('==') ? 2 : 1) : 0;
    final length = (clean.length * 3 ~/ 4) - padding;
    final out = BytesBuilder(copy: false);
    var buffer = 0, bits = 0;
    for (var i = 0; i < clean.length; i++) {
      final ch = clean[i];
      if (ch == '=') break;
      final val = lookup.indexOf(ch);
      if (val < 0) continue;
      buffer = (buffer << 6) | val;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.addByte((buffer >> bits) & 0xFF);
      }
    }
    return out.toBytes().sublist(0, length.clamp(0, out.length));
  }

  /// 注册（成功后直接返回登录态）。
  Future<ManwabaLoginResult> register({
    required String username,
    required String password,
    String email = '',
    String nickname = '',
    required String captchaId,
    required String captchaCode,
  }) async {
    final res = await _dio.post(
      '$_apiBase/user/register',
      options: Options(headers: _authHeaders),
      data: {
        'username': username,
        'password': password,
        if (email.isNotEmpty) 'email': email,
        if (nickname.isNotEmpty) 'nickname': nickname,
        'captchaId': captchaId,
        'captchaCode': captchaCode,
      },
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200 && data['data'] is Map) {
      final d = Map<String, dynamic>.from(data['data'] as Map);
      return ManwabaLoginResult(
        token: '${d['token'] ?? ''}',
        userId: '${d['userId'] ?? ''}',
        username: username,
        nickname: nickname.isEmpty ? null : nickname,
      );
    }
    _throwFrom(res, data);
  }

  // ── 收藏 ──

  /// 查询某漫画是否已收藏。
  Future<bool> checkFavorite(String comicId) async {
    final res = await _dio.get(
      '$_apiBase/user/favorite/check',
      queryParameters: {'comic_id': comicId},
      options: Options(headers: _authHeaders),
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200) {
      return data['data'] == true;
    }
    return false;
  }

  /// 添加收藏（categoryId 为空表示未分类）。
  Future<void> addFavorite(String comicId, {int categoryId = 0}) async {
    final res = await _dio.post(
      '$_apiBase/user/favorite/add',
      options: Options(
        headers: {
          ..._authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      ),
      data: 'comic_id=$comicId&category_id=$categoryId',
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200) return;
    _throwFrom(res, data);
  }

  /// 取消收藏。
  Future<void> deleteFavorite(String comicId) async {
    final res = await _dio.post(
      '$_apiBase/user/favorite/delete',
      options: Options(
        headers: {
          ..._authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      ),
      data: 'comic_id=$comicId',
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200) return;
    _throwFrom(res, data);
  }

  /// 分页拉取收藏列表。返回 (列表, 是否还有下一页)。
  Future<({List<ManwabaFavoriteItem> list, bool hasNext})> listFavorites({
    int page = 1,
    int pageSize = 30,
  }) async {
    final res = await _dio.get(
      '$_apiBase/user/favorites',
      queryParameters: {'page': page, 'page_size': pageSize, 'status': 'all'},
      options: Options(headers: _authHeaders),
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200 && data['data'] is Map) {
      final root = Map<String, dynamic>.from(data['data'] as Map);
      final rawList = (root['list'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final list = rawList.map((e) {
        return ManwabaFavoriteItem(
          comicId: '${e['comic_id'] ?? ''}',
          title: '${e['title'] ?? ''}',
          cover: '${e['cover'] ?? ''}',
          readChapter: e['read_chapter']?.toString(),
          latestChapter: e['latest_chapter']?.toString(),
          favoriteTime: _parseTime(e['favorite_time'] ?? e['edittime']),
        );
      }).where((e) => e.comicId.isNotEmpty).toList();
      final totalPage = (root['total_page'] as num?)?.toInt() ?? 1;
      return (list: list, hasNext: page < totalPage);
    }
    _throwFrom(res, data);
  }

  // ── 浏览记录 ──

  /// 分页拉取浏览记录。
  Future<({List<ManwabaHistoryItem> list, bool hasNext})> listHistory({
    int page = 1,
    int pageSize = 30,
  }) async {
    final res = await _dio.get(
      '$_apiBase/user/history',
      queryParameters: {'page': page, 'page_size': pageSize},
      options: Options(headers: _authHeaders),
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200 && data['data'] is Map) {
      final root = Map<String, dynamic>.from(data['data'] as Map);
      final rawList = (root['list'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final list = rawList.map((e) {
        // url 形如 /comic/123456 或 /comic/123456/123，从中解析 comicId。
        final url = '${e['url'] ?? ''}';
        var comicId = '${e['comic_id'] ?? ''}';
        if (comicId.isEmpty) {
          final m = RegExp(r'/comic/(\d+)(?:/(\d+))?').firstMatch(url);
          if (m != null) comicId = m.group(1) ?? '';
        }
        return ManwabaHistoryItem(
          id: '${e['id'] ?? ''}',
          comicId: comicId,
          chapterId: '${e['chapter_id'] ?? ''}',
          title: '${e['title'] ?? ''}',
          cover: '${e['cover'] ?? ''}',
          chapterTitle: e['chapterTitle']?.toString(),
          timestamp: _parseTime(e['timestamp']),
        );
      }).where((e) => e.title.isNotEmpty).toList();
      final totalPage = (root['total_page'] as num?)?.toInt() ?? 1;
      return (list: list, hasNext: page < totalPage);
    }
    _throwFrom(res, data);
  }

  /// 上报一次阅读记录（进入章节时调用）。
  Future<void> recordHistory(String comicId, String chapterId) async {
    if (comicId.isEmpty || chapterId.isEmpty) return;
    if (!UserManager().isManwabaLoggedIn) return;
    try {
      await _dio.post(
        '$_apiBase/user/history',
        options: Options(headers: _authHeaders),
        data: {'comicId': comicId, 'chapterId': chapterId},
      );
    } catch (_) {
      // 上报失败不阻塞阅读。
    }
  }

  /// 清空浏览记录。
  Future<void> clearHistory() async {
    final res = await _dio.post(
      '$_apiBase/user/history/clear',
      options: Options(headers: _authHeaders),
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200) return;
    _throwFrom(res, data);
  }

  /// 删除单条浏览记录。
  Future<void> deleteHistory(String id) async {
    final res = await _dio.post(
      '$_apiBase/user/history/delete',
      options: Options(
        headers: {
          ..._authHeaders,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      ),
      data: 'id=$id',
    );
    final data = res.data is Map<String, dynamic>
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    if (data['code'] == 200) return;
    _throwFrom(res, data);
  }

  DateTime? _parseTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) {
      final seconds = raw.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
        seconds < 1e12 ? seconds * 1000 : seconds,
      );
    }
    return DateTime.tryParse(raw.toString());
  }
}

/// 漫屋吧登录成功后的结果。
class ManwabaLoginResult {
  final String token;
  final String userId;
  final String username;
  final String? nickname;
  const ManwabaLoginResult({
    required this.token,
    required this.userId,
    required this.username,
    this.nickname,
  });
}

/// 漫屋吧收藏项。
class ManwabaFavoriteItem {
  final String comicId;
  final String title;
  final String cover;
  final String? readChapter;
  final String? latestChapter;
  final DateTime? favoriteTime;

  const ManwabaFavoriteItem({
    required this.comicId,
    required this.title,
    required this.cover,
    this.readChapter,
    this.latestChapter,
    this.favoriteTime,
  });

  Comic toComic() => Comic(
        name: title,
        pathWord: ManwabaSource.instance.encodeComicId(comicId),
        cover: ManwabaSource.instance.normalizeImageUrl(cover),
        authors: const [],
      );
}

/// 漫屋吧浏览记录项。
class ManwabaHistoryItem {
  final String id;
  final String comicId;
  final String chapterId;
  final String title;
  final String cover;
  final String? chapterTitle;
  final DateTime? timestamp;

  const ManwabaHistoryItem({
    required this.id,
    required this.comicId,
    required this.chapterId,
    required this.title,
    required this.cover,
    this.chapterTitle,
    this.timestamp,
  });

  Comic toComic() => Comic(
        name: title,
        pathWord: ManwabaSource.instance.encodeComicId(comicId),
        cover: ManwabaSource.instance.normalizeImageUrl(cover),
        authors: const [],
      );
}
