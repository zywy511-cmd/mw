import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

import '../api/api_client.dart';
import '../api/third_party/third_party_source.dart';
import '../api/third_party/third_party_sources.dart';
import '../l10n/app_localizations.dart';
import '../models/anime.dart';
import '../models/api_ordering.dart';
import '../models/comic.dart' as m;
import '../models/comic.dart' hide Theme;
import '../models/user_manager.dart';
import '../repositories/search_init_repository.dart';
import '../routing/app_router.dart';
import '../theme/app_spacing.dart';
import '../utils/cover_brightness_filter.dart';
import '../widgets/comic_card_skeleton.dart';
import '../widgets/comic_hero_tags.dart';
import 'home_page.dart' show ComicCard;

enum _SearchMode { comic, anime }

/// 单源搜索结果切片。
typedef _SourceSlice = ({
  List<Comic> comics,
  List<String> labels,
  int page,
  int maxPage,
  int total,
});

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _tagSpacing = 8.0;
  bool _refreshing = false;

  final _api = ApiClient();
  final _searchInitRepo = SearchInitRepository();
  final _user = UserManager();
  final _searchController = TextEditingController();

  List<String> _keywords = [];
  List<m.Theme> _tags = [];
  List<Comic> _comics = [];
  List<Anime> _animes = [];

  // ── 单源搜索状态 ──
  // 'manwaba'=漫屋吧（唯一漫源）
  static const _sourceOptions = [
    ('manwaba', '漫屋吧'),
  ];
  String _sourceFilter = 'manwaba'; // 搜索漫屋吧
  final Map<String, int> _sourcePages = {}; // 每源已加载页码
  final Map<String, int> _sourceMaxPages = {}; // 每源最大页码
  final Map<String, int> _sourceTotals = {}; // 每源总条数
  final List<String> _sourceLabels = []; // 与 _comics 逐项对齐的来源名
  int _pendingSearches = 0; // 并行首查未完成数

  // 「全部」模式源列表（仅漫屋吧）
  static const _allSources = ['manwaba'];

  // 漫屋吧分类标签
  static const _manwabaCategories = [
    '热血', '玄幻', '恋爱', '冒险', '古风', '都市', '穿越', '奇幻',
    '搞笑', '少年', '战斗', '重生', '逆袭', '韩漫', '完整版',
  ];

  String _sourceName(String key) {
    for (final (k, name) in _sourceOptions) {
      if (k == key) return name;
    }
    return key;
  }

  _SearchMode _mode = _SearchMode.comic;
  String? _selectedTag;
  String _ordering = ApiOrdering.popular;
  bool _loadingMore = false;
  bool _searching = false;
  int _offset = 0;
  int _total = 0;
  String? _searchQuery;

  bool get _animeFeatureEnabled => _user.animeFeatureEnabled;
  bool get _isAnimeMode => _animeFeatureEnabled && _mode == _SearchMode.anime;
  String _modeLabel(AppLocalizations l10n) =>
      _isAnimeMode ? l10n.animeLabel : l10n.comicLabel;
  bool get _hasResults => _comics.isNotEmpty || _animes.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _user.addListener(_onUserChanged);
    _loadFromCache();
    _loadInit();
  }

  @override
  void dispose() {
    _user.removeListener(_onUserChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onUserChanged() {
    if (!mounted) return;
    if (!_animeFeatureEnabled && _mode == _SearchMode.anime) {
      _setMode(_SearchMode.comic);
      return;
    }
    setState(() {});
  }

  Future<void> _loadFromCache() async {
    final cached = await _searchInitRepo.loadFromCache();
    if (!mounted || cached == null) return;
    setState(() {
      _keywords = cached.keywords;
      _tags = cached.tags;
    });
  }

  Future<void> _loadInit({bool forceRefresh = false}) async {
    setState(() => _refreshing = true);
    try {
      final data = await _searchInitRepo.load();
      if (!mounted) return;
      setState(() {
        _keywords = data.keywords;
        _tags = data.tags;
        _refreshing = false;
      });
    } catch (e) {
      debugPrint('SearchPage loadInit error: $e');
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _doSearch(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return;
    final mode = _animeFeatureEnabled ? _mode : _SearchMode.comic;
    setState(() {
      _mode = mode;
      _searching = true;
      _searchQuery = keyword;
      _comics = [];
      _animes = [];
      _offset = 0;
      _total = 0;
      _selectedTag = null;
      _sourceLabels.clear();
      _pendingSearches = 0;
    });

    try {
      if (mode == _SearchMode.anime) {
        final result = await _api.anime.searchAnimes(keyword);
        if (!mounted || _mode != mode || _searchQuery != keyword) return;
        setState(() {
          _animes = result.list;
          _total = result.total;
          _offset = result.list.length;
          _searching = false;
        });
      } else {
        await _doSearchComic(keyword, mode);
      }
    } catch (e) {
      debugPrint('SearchPage search error: $e');
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 单个源的第 page 页搜索结果（1-based）。
  Future<_SourceSlice> _searchSourcePage(
    String sourceKey,
    String keyword,
    int page,
  ) async {
    switch (sourceKey) {
      case 'hot':
        final r = await _api.manga.searchComics(
          keyword,
          offset: (page - 1) * 20,
        );
        return (
          comics: r.list,
          labels: List.filled(r.list.length, '热辣'),
          page: page,
          maxPage: r.total <= 0 ? 1 : ((r.total + 19) ~/ 20),
          total: r.total,
        );
      case 'copy':
        final r = await _api.manga.searchCopyComics(
          keyword,
          offset: (page - 1) * 20,
        );
        return (
          comics: r.list,
          labels: List.filled(r.list.length, '拷贝'),
          page: page,
          maxPage: r.total <= 0 ? 1 : ((r.total + 19) ~/ 20),
          total: r.total,
        );
      case 'hotcopy':
        // 热辣·拷贝合并源：两源同页并行 + 按标题去重（热辣优先）。
        // 页码以热辣为准推进（两源内容相同，页数一致）。
        final results = await Future.wait([
          _searchSourcePage('hot', keyword, page),
          _searchSourcePage('copy', keyword, page),
        ]);
        final merged = _mergeSlicesDedup(results);
        return (
          comics: merged.comics,
          labels: merged.labels,
          page: page,
          maxPage: results[0].maxPage,
          total: results[0].total,
        );
      default:
        final source = ThirdPartySources.byKey(sourceKey);
        if (source == null) {
          return (
            comics: const <Comic>[],
            labels: const <String>[],
            page: 1,
            maxPage: 1,
            total: 0,
          );
        }
        final r = await source.search(keyword, page);
        final total = r.maxPage * 20;
        return (
          comics: r.comics,
          labels: List.filled(r.comics.length, _sourceName(sourceKey)),
          page: page,
          maxPage: r.maxPage,
          total: total,
        );
    }
  }

  /// 按传入顺序合并多个切片并去重（保留先出现的，即优先级高的）。
  _SourceSlice _mergeSlicesDedup(List<_SourceSlice> slices) {
    final seen = <String>{};
    final comics = <Comic>[];
    final labels = <String>[];
    for (final s in slices) {
      for (var i = 0; i < s.comics.length; i++) {
        final key = s.comics[i].name.trim();
        if (key.isEmpty || !seen.add(key)) continue;
        comics.add(s.comics[i]);
        labels.add(s.labels[i]);
      }
    }
    return (
      comics: comics,
      labels: labels,
      page: slices.first.page,
      maxPage: slices.first.maxPage,
      total: slices.first.total,
    );
  }

  /// 「全部」模式：按 [order] 顺序把已完成的源结果追加进列表。
  /// 去重仅在本次追加的组内进行（热辣/拷贝间去重）；
  /// 漫屋3/漫屋吧 结果完整展示，不与热辣/拷贝互相过滤。
  void _appendAllSources(Map<String, _SourceSlice> results, List<String> order) {
    final seen = <String>{};
    for (final key in order) {
      final slice = results[key];
      if (slice == null) continue;
      for (var i = 0; i < slice.comics.length; i++) {
        final t = slice.comics[i].name.trim();
        if (t.isEmpty || !seen.add(t)) continue;
        _comics.add(slice.comics[i]);
        _sourceLabels.add(slice.labels[i]);
      }
    }
  }

  /// 漫画搜索：单源直接查；「全部」两源并行首查并聚合。
  Future<void> _doSearchComic(String keyword, _SearchMode mode) async {
    _sourcePages.clear();
    _sourceMaxPages.clear();
    _sourceTotals.clear();
    if (_sourceFilter == 'all') {
      _pendingSearches = _allSources.length;
      final results = <String, _SourceSlice>{};

      for (final key in _allSources) {
        unawaited(
          _searchSourcePage(key, keyword, 1).then((slice) {
            if (!mounted || _mode != mode || _searchQuery != keyword) return;
            setState(() {
              _sourcePages[key] = slice.page;
              _sourceMaxPages[key] = slice.maxPage;
              _sourceTotals[key] = slice.total;
              results[key] = slice;
              _appendAllSources(results, _allSources);
              _offset = _comics.length;
              _pendingSearches--;
              if (_pendingSearches <= 0) _searching = false;
            });
          }).catchError((e) {
            debugPrint('SearchPage $key search error: $e');
            if (!mounted || _mode != mode || _searchQuery != keyword) return;
            setState(() {
              _sourcePages[key] = 1;
              _sourceMaxPages[key] = 1;
              _sourceTotals[key] = 0;
              _pendingSearches--;
              if (_pendingSearches <= 0) _searching = false;
            });
          }),
        );
      }
      return;
    }

    final slice = await _searchSourcePage(_sourceFilter, keyword, 1);
    if (!mounted || _mode != mode || _searchQuery != keyword) return;
    setState(() {
      _sourcePages[_sourceFilter] = slice.page;
      _sourceMaxPages[_sourceFilter] = slice.maxPage;
      _sourceTotals[_sourceFilter] = slice.total;
      _comics = slice.comics;
      _sourceLabels.addAll(slice.labels);
      _total = slice.total;
      _offset = slice.comics.length;
      _searching = false;
    });
  }

  /// 「全部」模式加载更多：所有源并行取下一页并保序追加（跨源去重）。
  Future<void> _loadMoreAll() async {
    final keyword = _searchQuery;
    if (keyword == null) return;
    final results = <String, _SourceSlice>{};
    final tasks = <Future<void>>[];
    for (final key in _allSources) {
      final loaded = _sourcePages[key] ?? 0;
      final max = _sourceMaxPages[key] ?? 1;
      if (loaded >= max) continue;
      final next = loaded + 1;
      tasks.add(
        _searchSourcePage(key, keyword, next).then((slice) {
          if (!mounted || _searchQuery != keyword) return;
          setState(() {
            _sourcePages[key] = slice.page;
            _sourceMaxPages[key] = slice.maxPage;
            _sourceTotals[key] = slice.total;
            results[key] = slice;
          });
        }).catchError((e) {
          debugPrint('SearchPage $key loadMore error: $e');
        }),
      );
    }
    if (tasks.isEmpty) return;
    await Future.wait(tasks);
    if (!mounted || _searchQuery != keyword) return;
    setState(() {
      _appendAllSources(results, _allSources);
      _offset = _comics.length;
    });
  }

  Future<void> _loadComics({bool reset = true}) async {
    if (reset) {
      setState(() {
        _mode = _SearchMode.comic;
        _offset = 0;
        _total = 0;
        _comics = [];
        _animes = [];
        _searchQuery = null;
        _sourceLabels.clear();
        _sourcePages.clear();
        _sourceMaxPages.clear();
        _sourceTotals.clear();
        if (_selectedTag != null) _searching = true;
      });
    }
    try {
      final result = await _api.manga.getComicList(
        ordering: _ordering,
        offset: _offset,
        theme: _selectedTag,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _comics = result.list;
        } else {
          _comics.addAll(result.list);
        }
        _total = result.total;
        _offset = _comics.length;
        _searching = false;
      });
    } catch (e) {
      debugPrint('SearchPage loadComics error: $e');
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _offset >= _total) return;
    setState(() => _loadingMore = true);
    try {
      if (_searchQuery != null) {
        if (_isAnimeMode) {
          final result = await _api.anime.searchAnimes(
            _searchQuery!,
            offset: _offset,
          );
          if (!mounted) return;
          setState(() {
            _animes.addAll(result.list);
            _offset = _animes.length;
          });
        } else if (_sourceFilter == 'all') {
          await _loadMoreAll();
        } else {
          // 单源翻页：用每源页码推进
          final key = _sourceFilter;
          final loaded = _sourcePages[key] ?? 1;
          final max = _sourceMaxPages[key] ?? 1;
          if (loaded < max) {
            final slice = await _searchSourcePage(
              key,
              _searchQuery!,
              loaded + 1,
            );
            if (!mounted) return;
            setState(() {
              _sourcePages[key] = slice.page;
              _sourceMaxPages[key] = slice.maxPage;
              _sourceTotals[key] = slice.total;
              _comics.addAll(slice.comics);
              _sourceLabels.addAll(slice.labels);
              _offset = _comics.length;
              _total = slice.maxPage * 20;
            });
          }
        }
      } else if (!_isAnimeMode) {
        await _loadComics(reset: false);
      }
    } catch (e) {
      debugPrint('SearchPage loadMore error: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      } else {
        _loadingMore = false;
      }
    }
  }

  void _setMode(_SearchMode mode) {
    if (mode == _SearchMode.anime && !_animeFeatureEnabled) return;
    if (_mode == mode) return;
    final keyword = _searchController.text.trim();
    setState(() {
      _mode = mode;
      _selectedTag = null;
      _comics = [];
      _animes = [];
      _offset = 0;
      _total = 0;
      _searchQuery = keyword.isEmpty ? null : keyword;
      _sourceLabels.clear();
      _sourcePages.clear();
      _sourceMaxPages.clear();
      _sourceTotals.clear();
      _pendingSearches = 0;
    });
    if (keyword.isNotEmpty) {
      _doSearch(keyword);
    }
  }

  void _selectTag(String? tagPathWord) {
    _searchController.clear();
    final isToggleOff = tagPathWord != null && _selectedTag == tagPathWord;
    final next = isToggleOff ? null : tagPathWord;
    setState(() {
      _mode = _SearchMode.comic;
      _selectedTag = next;
      _searchQuery = null;
      _searching = next != null;
      _offset = 0;
      _total = 0;
      _comics = [];
      _animes = [];
      _sourceLabels.clear();
      _sourcePages.clear();
      _sourceMaxPages.clear();
      _sourceTotals.clear();
      _sourceFilter = 'manwaba'; // 标签浏览后搜索默认使用漫屋吧
    });
    if (next != null) {
      _loadComics();
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = null;
      _comics = [];
      _animes = [];
      _offset = 0;
      _total = 0;
      _sourceLabels.clear();
      _sourcePages.clear();
      _sourceMaxPages.clear();
      _sourceTotals.clear();
      _pendingSearches = 0;
    });
  }

  void _onKeywordTap(String keyword) {
    _searchController.text = keyword;
    _doSearch(keyword);
  }

  void _openAnime(Anime anime) {
    if (!_animeFeatureEnabled) return;
    if (anime.pathWord.isEmpty) return;
    context.pushNamed(
      AppRoutes.animeDetail,
      pathParameters: {'pathWord': anime.pathWord},
      extra: AnimeDetailExtra(initialAnime: anime),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final contentWidth = screenWidth.clamp(0.0, 900.0);
    final hp = (screenWidth - contentWidth) / 2 + 16;

    return RefreshIndicator(
      onRefresh: () => _loadInit(forceRefresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (_hasResults &&
              n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
            _loadMore();
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: SizedBox(height: MediaQuery.of(context).padding.top),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(hp, 12, hp, 8),
                child: SearchBar(
                  controller: _searchController,
                  hintText: l10n.searchHint(_modeLabel(l10n)),
                  leading: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.search),
                  ),
                  trailing: _searchQuery != null
                      ? [
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: _clearSearch,
                          ),
                        ]
                      : null,
                  onSubmitted: _doSearch,
                ),
              ),
            ),
            if (_animeFeatureEnabled)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hp, 0, hp, 8),
                  child: SegmentedButton<_SearchMode>(
                    segments: [
                      ButtonSegment(
                        value: _SearchMode.comic,
                        label: Text(l10n.comicLabel),
                        icon: const Icon(Icons.menu_book_outlined),
                      ),
                      ButtonSegment(
                        value: _SearchMode.anime,
                        label: Text(l10n.animeLabel),
                        icon: const Icon(Icons.movie_outlined),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (v) => _setMode(v.first),
                  ),
                ),
              ),
            if (_refreshing &&
                _searchQuery == null &&
                _selectedTag == null &&
                !_searching &&
                _keywords.isEmpty &&
                _tags.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: ExpressiveLoadingIndicator()),
              ),
            if (_searching && _selectedTag == null)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: hp),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (_, _) => const ComicCardSkeleton(),
                    childCount: 20,
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    childAspectRatio: 0.55,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                ),
              ),
            if (!_isAnimeMode &&
                _searchQuery == null &&
                _selectedTag == null &&
                !_searching)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hp, 8, hp, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.category, size: 20, color: cs.primary),
                          const SizedBox(width: 6),
                          Text(
                            '漫屋吧分类',
                            style: tt.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Wrap(
                        spacing: _tagSpacing,
                        runSpacing: _tagSpacing,
                        children: [
                          for (final cat in _manwabaCategories)
                            FilterChip(
                              label: Text(cat),
                              selected: _selectedTag == cat,
                              showCheckmark: false,
                              onSelected: (_) {
                                _searchController.text = cat;
                                _doSearch(cat);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                  ),
                ),
              ),
            if (!_isAnimeMode && _selectedTag != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hp, 0, hp, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: ApiOrdering.popular,
                            label: Text(l10n.popularOrder),
                            icon: const Icon(Icons.whatshot),
                          ),
                          ButtonSegment(
                            value: ApiOrdering.datetimeUpdated,
                            label: Text(l10n.updateOrder),
                            icon: const Icon(Icons.schedule),
                          ),
                        ],
                        selected: {_ordering},
                        onSelectionChanged: (v) {
                          setState(() => _ordering = v.first);
                          _loadComics();
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                  ),
                ),
              ),
            if (_searching && _selectedTag != null)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: hp),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (_, _) => const ComicCardSkeleton(),
                    childCount: 21,
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    childAspectRatio: 0.55,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                ),
              ),
            if (_searchQuery != null && _hasResults)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hp, 4, hp, 12),
                  child: Text(
                    l10n.searchResultSummary(
                      _searchQuery!,
                      _total,
                      _modeLabel(l10n),
                    ),
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            if (!_isAnimeMode && _comics.isNotEmpty)
              _ComicGrid(
                comics: _comics,
                sourceLabels: _sourceLabels.isEmpty ? null : _sourceLabels,
                hp: hp,
                loadingMore: _loadingMore,
                onOpen: (comic, heroTagBase) {
                  // 第三方漫源详情页无 Hero 组件，跳过飞行动画避免异常。
                  final isThirdParty =
                      ThirdPartyComicSource.sourceKeyOfPathWord(
                        comic.pathWord,
                      ) !=
                      null;
                  context.pushNamed(
                    AppRoutes.comicDetail,
                    pathParameters: {'pathWord': comic.pathWord},
                    extra: ComicDetailExtra(
                      initialComic: comic,
                      heroTagBase: isThirdParty ? null : heroTagBase,
                    ),
                  );
                },
              ),
            if (_isAnimeMode && _animes.isNotEmpty)
              _AnimeGrid(
                animes: _animes,
                hp: hp,
                loadingMore: _loadingMore,
                onOpen: _openAnime,
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
          ],
        ),
      ),
    );
  }
}

class _ComicGrid extends StatelessWidget {
  final List<Comic> comics;
  final List<String>? sourceLabels;
  final double hp;
  final bool loadingMore;
  final void Function(Comic comic, String heroTagBase) onOpen;

  const _ComicGrid({
    required this.comics,
    this.sourceLabels,
    required this.hp,
    required this.loadingMore,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: hp),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate((_, i) {
          if (i >= comics.length) {
            return const ComicCardSkeleton();
          }
          final comic = comics[i];
          final heroTagBase = ComicHeroTags.base(
            scope: 'search',
            pathWord: comic.pathWord,
            index: i,
          );
          final label = sourceLabels != null && i < sourceLabels!.length
              ? sourceLabels![i]
              : null;
          return _SourceBadge(
            label: label,
            child: ComicCard(
              comic: comic,
              heroTagBase: heroTagBase,
              onTap: () => onOpen(comic, heroTagBase),
            ),
          );
        }, childCount: comics.length + (loadingMore ? 6 : 0)),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          childAspectRatio: 0.55,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
      ),
    );
  }
}

/// 漫画卡片左上角来源角标（聚合搜索时区分 热辣/拷贝/漫屋3/漫屋吧）。
class _SourceBadge extends StatelessWidget {
  final String? label;
  final Widget child;

  const _SourceBadge({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    if (label == null) return child;
    return Stack(
      children: [
        child,
        Positioned(
          top: 4,
          left: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AnimeGrid extends StatelessWidget {
  final List<Anime> animes;
  final double hp;
  final bool loadingMore;
  final ValueChanged<Anime> onOpen;

  const _AnimeGrid({
    required this.animes,
    required this.hp,
    required this.loadingMore,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: hp),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate((_, i) {
          if (i >= animes.length) {
            return const ComicCardSkeleton();
          }
          final anime = animes[i];
          return _AnimeGridItem(anime: anime, onTap: () => onOpen(anime));
        }, childCount: animes.length + (loadingMore ? 6 : 0)),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          childAspectRatio: 0.55,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
      ),
    );
  }
}

class _AnimeGridItem extends StatelessWidget {
  final Anime anime;
  final VoidCallback onTap;

  const _AnimeGridItem({required this.anime, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              margin: EdgeInsets.zero,
              child: CoverBrightnessFilter(
                child: CachedNetworkImage(
                  imageUrl: anime.cover,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  placeholder: (_, _) => Container(
                    color: cs.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.movie_outlined,
                        color: cs.onSurfaceVariant,
                        size: 32,
                      ),
                    ),
                  ),
                  errorWidget: (_, _, _) => Container(
                    color: cs.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.broken_image,
                        color: cs.onSurfaceVariant,
                        size: 32,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            anime.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
