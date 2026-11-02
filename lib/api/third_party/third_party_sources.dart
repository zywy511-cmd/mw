import 'manwaba_source.dart';
import 'third_party_source.dart';

/// 第三方漫源注册表：仅保留漫屋吧。
class ThirdPartySources {
  ThirdPartySources._();

  static final List<ThirdPartyComicSource> all = [
    ManwabaSource.instance,
  ];

  static ThirdPartyComicSource? byKey(String key) {
    for (final source in all) {
      if (source.key == key) return source;
    }
    return null;
  }
}
