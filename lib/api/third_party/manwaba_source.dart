import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/comic.dart';
import '../../models/user_manager.dart';
import '../../utils/app_dio.dart';
import 'third_party_source.dart';

/// 漫屋吧 漫源（Venera 源 `mwb.js` 的 Dart 移植）。
///
/// 站点特征：
///  - API 响应为明文 JSON（`code=200` 时 `data` 携带板块/搜索结果）。
///  - 支持域名自动检测（防走失页 + 候选域名探测），结果缓存到本地。
///  - 封面/图片 URL 需经 [normalizeImageUrl] 重写旧图源到当前可用图源。
class ManwabaSource extends ThirdPartyComicSource {
  ManwabaSource._();

  static final ManwabaSource instance = ManwabaSource._();

  @override
  String get key => 'manwaba';

  @override
  String get name => '漫屋吧';

  // ── 站点常量（与 Venera 源一致）──
  static const defaultApiHost = 'manwabb.cc';
  static const defaultImageHost = 'tu.mwzu.cc';
  static const lostPageHosts = ['https://manwami.cc', 'https://manwala.cc'];
  static const candidateApiHosts = [
    'manwabb.cc',
    'manwali.cc',
    'manwaye.cc',
    'manwalu.cc',
    'mwmw.cc',
  ];
  static const candidateImageHosts = [
    'tu.mwzu.cc',
    'mwtuwu.cc',
    'mwtuyi.cc',
    'mwtuer.cc',
    'mwtusan.cc',
  ];

  /// 设置下拉选项：漫画站域名。
  static const apiHostOptions = [
    ('auto', '自动检测(推荐)'),
    ('manwabb.cc', 'manwabb.cc'),
    ('manwali.cc', 'manwali.cc'),
    ('manwaye.cc', 'manwaye.cc'),
    ('manwalu.cc', 'manwalu.cc'),
    ('mwmw.cc', 'mwmw.cc'),
  ];

  /// 设置下拉选项：图片源。
  static const imageHostOptions = [
    ('auto', '自动检测(推荐)'),
    ('tu.mwzu.cc', 'tu.mwzu.cc (高速源)'),
    ('mwtuwu.cc', 'mwtuwu.cc (稳定源)'),
    ('mwtuyi.cc', 'mwtuyi.cc'),
    ('mwtuer.cc', 'mwtuer.cc'),
  ];

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  late final Dio _dio = AppDio.create(
    source: key,
    enableRateLimit: false,
    options: BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      validateStatus: (_) => true,
    ),
  );

  bool _detectStarted = false;

  // ── 域名解析：手动设置 > 自动检测缓存 > 默认值 ──

  String _manualApiHost() {
    final value = UserManager().manwabaApiHost.trim();
    return (value.isEmpty || value == 'auto') ? '' : value;
  }

  String _manualImageHost() {
    final value = UserManager().manwabaImageHost.trim();
    return (value.isEmpty || value == 'auto') ? '' : value;
  }

  /// 规范化 host：去协议、去首尾斜杠、只取第一段。
  static String _norm(String host) {
    return host
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'^/+|/+$'), '')
        .split('/')
        .first;
  }

  /// 当前生效的 API 域名（不含协议和 /api）。
  String get currentApiHost {
    final manual = _manualApiHost();
    if (manual.isNotEmpty) return manual;
    final cached = UserManager().manwabaDetectedApiHost.trim();
    if (cached.isNotEmpty) return cached;
    return defaultApiHost;
  }

  /// 当前生效的图片源域名。
  String get currentImageHost {
    final manual = _manualImageHost();
    if (manual.isNotEmpty) return manual;
    final cached = UserManager().manwabaDetectedImageHost.trim();
    if (cached.isNotEmpty) return cached;
    return defaultImageHost;
  }

  String get api => 'https://${_norm(currentApiHost)}/api';

  String get imageSource => 'https://${_norm(currentImageHost)}';

  /// 统一图片 URL：补全协议，并把失效的旧图源域名重写到当前可用图源。
  String normalizeImageUrl(String url) {
    final value = url.trim();
    if (value.isEmpty) return '';
    var result = value.startsWith('//') ? 'https:$value' : value;
    final host = imageSource;
    result = result.replaceFirstMapped(
      RegExp(
        r'^(https?://)(?:www\.)?(?:tu\.mhttu\.cc|mwtuyi\.cc|mwtuer\.cc|mwtusan\.cc|mwtuwu\.cc|tu\.mwzu\.cc)(/|$)',
        caseSensitive: false,
      ),
      (m) => '$host${m.group(2)}',
    );
    return result;
  }

  // ── 请求 ──

  Future<Map<String, dynamic>> _fetchJson(
    String url, {
    Map<String, dynamic>? params,
  }) async {
    final res = await _dio.get(
      url,
      queryParameters: params,
      options: Options(headers: {'User-Agent': userAgent}),
    );
    if (res.statusCode != 200) {
      throw '漫屋吧 API 请求失败: ${res.statusCode}';
    }
    final data = res.data;
    if (data is! Map<String, dynamic>) {
      throw '漫屋吧 API 响应格式异常';
    }
    return data;
  }

  // ── 数据映射 ──

  Comic _buildComic(
    Map<String, dynamic> item, {
    required String coverField,
    bool withDescription = false,
  }) {
    final id = '${item['id'] ?? ''}';
    final name = '${item['title'] ?? ''}';
    final author = '${item['author'] ?? ''}'.trim();
    final authors = author.isEmpty
        ? const <Author>[]
        : <Author>[Author(name: author, pathWord: '')];
    final tags = '${item['tags'] ?? ''}'
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final themes = tags.map((t) => Theme(name: t, pathWord: '')).toList();
    final rawStatus = item['status'];
    Map<String, dynamic>? status;
    if (rawStatus is num || rawStatus is String) {
      final intStatus = rawStatus is num ? rawStatus.toInt() : int.tryParse(rawStatus.toString());
      if (intStatus != null) {
        status = {'display': intStatus == 0 ? '连载中' : '已完结'};
      }
    }
    return Comic(
      name: name,
      pathWord: encodeComicId(id),
      cover: normalizeImageUrl('${item[coverField] ?? ''}'),
      authors: authors,
      themes: themes,
      brief: withDescription ? '${item['description'] ?? ''}' : null,
      status: status,
    );
  }

  // ── 主页板块 ──

  @override
  Future<Map<String, List<Comic>>> loadHome() async {
    unawaited(ensureDetection());
    final data = await _fetchJson(
      '$api/home',
      params: {'page': 1, 'pageSize': 6, 'type': '', 'flag': false},
    );
    if (data['code'] != 200) {
      throw '漫屋吧 首页加载失败: ${data['message'] ?? ''}';
    }
    final root = data['data'];
    if (root is! Map<String, dynamic>) {
      throw '漫屋吧 首页数据异常';
    }
    final sections = <String, List<Comic>>{
      '最新更新': _parseList(root['xuanhuanList']),
      '热门收藏': _parseList(root['xiaoyuanList']),
      '热门': _parseList(root['comicList']),
      '最新完整版': _parseList(root['gufengList']),
    };
    final result = <String, List<Comic>>{};
    for (final entry in sections.entries) {
      if (entry.value.isNotEmpty) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  List<Comic> _parseList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) => _buildComic(e, coverField: 'pic'))
        .toList();
  }

  // ── 搜索 ──

  @override
  Future<ThirdPartySearchResult> search(String keyword, int page) async {
    unawaited(ensureDetection());
    const pageSize = 20;
    final data = await _fetchJson(
      '$api/search',
      params: {
        'keyword': keyword,
        'type': 'mh',
        'page': page,
        'pageSize': pageSize,
      },
    );
    if (data['code'] != 200) {
      throw '漫屋吧 搜索失败: ${data['message'] ?? ''}';
    }
    final root = data['data'];
    if (root is! Map<String, dynamic>) {
      throw '漫屋吧 搜索数据异常';
    }
    final list = (root['list'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((e) => _buildComic(e, coverField: 'cover', withDescription: true))
            .toList() ??
        const <Comic>[];
    final total = (root['total'] as num?)?.toInt() ?? list.length;
    return ThirdPartySearchResult(
      comics: list,
      maxPage: pageSize <= 0 ? 1 : (total / pageSize).ceil(),
    );
  }

  // ── 漫画详情 / 章节 / 图片 ──

  @override
  Future<ThirdPartyComicDetail> loadInfo(String comicId) async {
    final data = await _fetchJson('$api/comic/$comicId');
    if (data['code'] != 200) {
      throw '漫屋吧 详情加载失败: ${data['message'] ?? ''}';
    }
    final root = data['data'];
    if (root is! Map<String, dynamic>) {
      throw '漫屋吧 详情数据异常';
    }
    // 章节列表：先取总数，再全量拉取
    final chapterId = '${root['id'] ?? ''}';
    var chapters = <ThirdPartyChapter>[];
    if (chapterId.isNotEmpty) {
      final pageRes = await _fetchJson(
        '$api/comic/chapter',
        params: {'comicId': chapterId, 'page': 1, 'pageSize': 1},
      );
      final pagination = pageRes['pagination'];
      final total = pagination is Map
          ? (pagination['total'] as num?)?.toInt() ?? 0
          : 0;
      if (total > 0) {
        final chapterRes = await _fetchJson(
          '$api/comic/chapter',
          params: {
            'comicId': chapterId,
            'page': 1,
            'pageSize': total,
          },
        );
        final list = chapterRes['data'];
        if (list is List) {
          chapters = list
              .whereType<Map<String, dynamic>>()
              .map(
                (item) => ThirdPartyChapter(
                  id: '${item['id'] ?? ''}',
                  name: '${item['title'] ?? ''}',
                ),
              )
              .where((c) => c.id.isNotEmpty)
              .toList();
        }
      }
    }
    final statusNum = root['status'];
    final statusDisplay = statusNum == 0
        ? '连载中'
        : (statusNum == 1 ? '已完结' : null);
    return ThirdPartyComicDetail(
      title: '${root['title'] ?? ''}',
      cover: normalizeImageUrl('${root['cover'] ?? ''}'),
      description: '${root['intro'] ?? ''}',
      authors: '${root['author'] ?? ''}'
          .split(RegExp(r'[/、,，]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      tags: '${root['tags'] ?? ''}'
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      statusDisplay: statusDisplay,
      updateTime: root['editTime'] is num
          ? _formatTimestamp((root['editTime'] as num).toInt())
          : null,
      chapters: chapters,
    );
  }

  String _formatTimestamp(int seconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final y = dt.year;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  Future<List<String>> loadEp(String comicId, String epId) async {
    final imgApi = '$api/comic/image/$epId';
    final params = {
      'page': 1,
      'pageSize': 1,
      // 参数名必须用 image_source（下划线），旧 imageSource（驼峰）会被服务端忽略
      'image_source': imageSource,
    };
    final first = await _fetchJson(imgApi, params: params);
    final pagination = first['data'] is Map
        ? (first['data'] as Map)['pagination']
        : null;
    final total = pagination is Map
        ? (pagination['total'] as num?)?.toInt() ?? 0
        : 0;
    if (total <= 0) return const [];
    final full = await _fetchJson(
      imgApi,
      params: {
        'page': 1,
        'page_size': total,
        'image_source': imageSource,
      },
    );
    final images = full['data'] is Map
        ? (full['data'] as Map)['images']
        : null;
    if (images is! List) return const [];
    return images
        .whereType<Map<String, dynamic>>()
        .map((item) => normalizeImageUrl('${item['url'] ?? ''}'))
        .where((url) => url.isNotEmpty)
        .toList();
  }

  @override
  ThirdPartyImageRequest? imageRequest(String url) {
    return ThirdPartyImageRequest(
      headers: {'User-Agent': userAgent},
      decryptor: (bytes) {
        if (ThirdPartyComicSource.isPlainImage(bytes)) return bytes;
        if (bytes.length < 32) return bytes;
        // key = '0B6666A0-BB59-1381-B746-a0E4C9AC' 的 UTF-8 前 32 字节
        // IV = 密文前 16 字节；密文 = 剩余部分
        const keyText = '0B6666A0-BB59-1381-B746-a0E4C9AC';
        final keyBytes = Uint8List.fromList(utf8.encode(keyText));
        final key = keyBytes.length > 32
            ? Uint8List.sublistView(keyBytes, 0, 32)
            : keyBytes;
        final iv = Uint8List.sublistView(bytes, 0, 16);
        final cipher = Uint8List.sublistView(bytes, 16);
        final decrypted =
            ThirdPartyComicSource.aesCbcDecrypt(cipher, key, iv);
        final unpadded = ThirdPartyComicSource.stripPkcs7(decrypted);
        if (ThirdPartyComicSource.isPlainImage(unpadded)) return unpadded;
        return bytes;
      },
    );
  }

  // ── 自动检测 ──

  /// 懒触发：手动未指定且未检测过时，后台执行一次自动检测。
  Future<void> ensureDetection() async {
    if (_detectStarted) return;
    if (_manualApiHost().isNotEmpty && _manualImageHost().isNotEmpty) return;
    _detectStarted = true;
    try {
      await autoDetect();
    } catch (_) {
      // 检测失败时保持默认域名，不阻塞使用
    }
  }

  /// 自动检测可用域名（防走失页 + 候选域名探测），结果缓存到本地。
  Future<({String apiHost, String imageHost})> autoDetect() async {
    final detectDio = AppDio.create(
      source: key,
      enableRateLimit: false,
      options: BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (_) => true,
      ),
    );

    // 1. 从防走失页提取候选域名
    final found = <String>{};
    for (final page in lostPageHosts) {
      try {
        final res = await detectDio.get(
          page,
          options: Options(headers: {'User-Agent': userAgent}),
        );
        if (res.data is String) {
          final html = res.data as String;
          for (final m in RegExp(r"""https?://[^\s"'<>]+""").allMatches(html)) {
            try {
              final host = Uri.parse(m.group(0)!).host;
              if (host.endsWith('mw.com') || host.endsWith('.cc')) {
                found.add(host);
              }
            } catch (_) {
              // 忽略非法 URL
            }
          }
        }
      } catch (_) {
        // 走失页不可达则跳过
      }
    }

    // 2. 测试候选 API 域名；成功后顺带测试图片源
    final apiCandidates = <String>{...found, ...candidateApiHosts};
    String? usableApiHost;
    String? usableImageHost;
    for (final host in apiCandidates) {
      try {
        final res = await detectDio.get(
          'https://$host/api/home',
          queryParameters: const {'page': 1, 'pageSize': 1},
          options: Options(headers: {'User-Agent': userAgent}),
        );
        if (res.statusCode != 200 || res.data is! Map) continue;
        final data = res.data as Map;
        if (data['code'] != 200) continue;
        usableApiHost = host;

        // 3. 用首页封面测试图片源
        final root = data['data'];
        if (root is Map && root['comicList'] is List) {
          final first = (root['comicList'] as List).isNotEmpty
              ? (root['comicList'] as List).first
              : null;
          if (first is Map) {
            final cover = '${first['pic'] ?? ''}';
            if (cover.isNotEmpty) {
              String? coverHost;
              try {
                coverHost = Uri.parse(cover).host;
              } catch (_) {}
              final imgCandidates = <String>{
                if (coverHost != null && coverHost.isNotEmpty) coverHost,
                ...candidateImageHosts,
              };
              for (final imgHost in imgCandidates) {
                try {
                  final normalized = _normalizeImageUrlWithHost(cover, imgHost);
                  final ir = await detectDio.head(
                    normalized,
                    options: Options(headers: {'User-Agent': userAgent}),
                  );
                  final code = ir.statusCode;
                  if (code != null && code >= 200 && code < 400) {
                    usableImageHost = imgHost;
                    break;
                  }
                } catch (_) {
                  // 该图源不可用，尝试下一个
                }
              }
            }
          }
        }
        break;
      } catch (_) {
        // 该 API 域名不可达，尝试下一个
      }
    }

    final apiHost = usableApiHost ?? defaultApiHost;
    final imageHost = usableImageHost ?? defaultImageHost;
    await UserManager().setManwabaDetectedApiHost(apiHost);
    await UserManager().setManwabaDetectedImageHost(imageHost);
    return (apiHost: apiHost, imageHost: imageHost);
  }

  String _normalizeImageUrlWithHost(String url, String host) {
    final value = url.trim();
    if (value.isEmpty) return '';
    final result = value.startsWith('//') ? 'https:$value' : value;
    final source = 'https://${_norm(host)}';
    return result.replaceFirstMapped(
      RegExp(
        r'^(https?://)(?:www\.)?(?:tu\.mhttu\.cc|mwtuyi\.cc|mwtuer\.cc|mwtusan\.cc|mwtuwu\.cc|tu\.mwzu\.cc)(/|$)',
        caseSensitive: false,
      ),
      (m) => '$source${m.group(2)}',
    );
  }
}
