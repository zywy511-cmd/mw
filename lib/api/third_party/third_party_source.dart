import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../models/comic.dart' hide Theme;

/// 第三方漫源统一搜索结果。
class ThirdPartySearchResult {
  final List<Comic> comics;
  final int maxPage;

  const ThirdPartySearchResult({required this.comics, required this.maxPage});
}

/// 第三方漫源章节。
class ThirdPartyChapter {
  final String id;
  final String name;

  const ThirdPartyChapter({required this.id, required this.name});
}

/// 第三方漫源详情（含章节列表，按阅读顺序排序：旧 -> 新）。
class ThirdPartyComicDetail {
  final String title;
  final String cover;
  final String description;
  final List<String> authors;
  final List<String> tags;
  final String? statusDisplay;
  final String? updateTime;
  final List<ThirdPartyChapter> chapters;

  const ThirdPartyComicDetail({
    required this.title,
    required this.cover,
    required this.description,
    this.authors = const [],
    this.tags = const [],
    this.statusDisplay,
    this.updateTime,
    this.chapters = const [],
  });
}

/// 第三方图片加载请求配置：请求头 + 可选的字节解密器。
class ThirdPartyImageRequest {
  final Map<String, String> headers;

  /// 输入源站原始字节，输出可显示的图片字节。
  /// 实现内必须先探测图片 magic bytes：明文直接原样返回，密文再解密。
  final Uint8List Function(Uint8List bytes)? decryptor;

  const ThirdPartyImageRequest({this.headers = const {}, this.decryptor});
}

/// 第三方漫源抽象（漫屋吧）。
///
/// 本轮覆盖：主页板块 + 关键词搜索 + 详情/章节 + 章节图片 + 图片解密加载。
abstract class ThirdPartyComicSource {
  /// 源 key：`manwaba`，用于 pathWord 前缀与设置持久化。
  String get key;

  /// 展示名：漫屋吧。
  String get name;

  /// 主页板块：板块标题 -> 漫画列表。
  Future<Map<String, List<Comic>>> loadHome();

  /// 关键词搜索（page 从 1 开始）。
  Future<ThirdPartySearchResult> search(String keyword, int page);

  /// 漫画详情（含章节列表）。
  Future<ThirdPartyComicDetail> loadInfo(String comicId);

  /// 章节图片 URL 列表（按阅读顺序）。
  Future<List<String>> loadEp(String comicId, String epId);

  /// 图片加载配置；null 表示普通直链（无 headers/解密需求）。
  ThirdPartyImageRequest? imageRequest(String url);

  /// 生成带源前缀的 pathWord，避免跨源 id 冲突：`manwaba:123456`。
  String encodeComicId(String comicId) => '$key:$comicId';

  /// 从 pathWord 反向解析源 key；非第三方 pathWord 返回 null。
  static String? sourceKeyOfPathWord(String pathWord) {
    final sep = pathWord.indexOf(':');
    if (sep <= 0) return null;
    return pathWord.substring(0, sep);
  }

  /// 从带前缀的 pathWord 取出纯漫画 id（`manwaba:123456` -> `123456`）。
  static String comicIdOfPathWord(String pathWord) {
    final sep = pathWord.indexOf(':');
    return sep <= 0 ? pathWord : pathWord.substring(sep + 1);
  }

  /// 判断是否为明文图片（JPEG/PNG/GIF/BMP/WebP magic bytes）。
  static bool isPlainImage(Uint8List b) {
    if (b.length < 12) return false;
    // JPEG
    if (b[0] == 0xFF && b[1] == 0xD8) return true;
    // PNG
    if (b[0] == 0x89 && b[1] == 0x50) return true;
    // GIF
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
    // BMP
    if (b[0] == 0x42 && b[1] == 0x4D) return true;
    // WebP: 'RIFF' + size + 'WEBP'
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return true;
    }
    return false;
  }

  /// 通用图片解密：探测 magic bytes，明文直接返回，密文尝试 AES-CBC 解密。
  /// [key] 与 [iv] 均为 UTF-8 字节；解密失败时返回原字节（避免崩溃）。
  static Uint8List probeOrDecryptCbc(
    Uint8List bytes, {
    required Uint8List key,
    required Uint8List iv,
  }) {
    if (isPlainImage(bytes)) return bytes;
    try {
      final decrypted = aesCbcDecrypt(bytes, key, iv);
      if (isPlainImage(decrypted)) return decrypted;
      return bytes;
    } catch (_) {
      return bytes;
    }
  }

  /// AES-CBC 解密（pointycastle），自动按 key 长度选 128/192/256。
  static Uint8List aesCbcDecrypt(Uint8List cipher, Uint8List key, Uint8List iv) {
    // 密文必须为 16 字节块的整数倍，超出部分截断。
    final block = (cipher.length ~/ 16) * 16;
    if (block == 0) return cipher;
    final usable = block == cipher.length
        ? cipher
        : Uint8List.sublistView(cipher, 0, block);
    final engine = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(usable.length);
    var off = 0;
    while (off < usable.length) {
      off += engine.processBlock(usable, off, out, off);
    }
    return out;
  }

  /// 去掉 PKCS7 填充（校验失败时原样返回）。
  static Uint8List stripPkcs7(Uint8List data) {
    final len = data.length;
    if (len == 0) return data;
    final padLen = data[len - 1];
    if (padLen == 0 || padLen > 16 || padLen > len) return data;
    for (var i = len - padLen; i < len; i++) {
      if (data[i] != padLen) return data;
    }
    return Uint8List.sublistView(data, 0, len - padLen);
  }
}
