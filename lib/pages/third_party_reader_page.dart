import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

import '../api/third_party/manwaba_auth.dart';
import '../api/third_party/third_party_source.dart';
import '../api/third_party/third_party_sources.dart';
import '../l10n/app_localizations.dart';
import '../models/user_manager.dart';
import '../theme/app_spacing.dart';
import '../theme/reader_chrome.dart';
import '../utils/local_history.dart';
import '../utils/third_party_reading_progress.dart';
import '../widgets/reader_status_overlay.dart';
import '../widgets/third_party_image.dart';

/// 第三方漫源（漫屋3/漫屋吧）阅读器，交互与拷贝漫画阅读器保持一致：
/// - 点击画面切换上下黑边控制栏（顶部：返回+章节名；底部：进度条+章节/设置）
/// - 支持滚动 / 翻页两种阅读模式（设置与拷贝漫画共享，持久化于 UserManager）
/// - 连续阅读：开启后翻到章节末尾自动拼接下一话，无需手动切换（默认开启）
/// - 阅读进度自动本地保存（记录到章节 + 话内页码），详情页「继续阅读」断点续读
class ThirdPartyReaderPage extends StatefulWidget {
  final String sourceKey;
  final String comicId;
  final String comicName;
  final List<ThirdPartyChapter> chapters; // 阅读顺序（旧->新，第一话在前）
  final int initialIndex;
  final int initialPage;

  const ThirdPartyReaderPage({
    super.key,
    required this.sourceKey,
    required this.comicId,
    required this.comicName,
    required this.chapters,
    required this.initialIndex,
    this.initialPage = 1,
  });

  @override
  State<ThirdPartyReaderPage> createState() => _ThirdPartyReaderPageState();
}

/// 连续阅读链中的一章：章节引用 + 已加载图片 + 在章节列表中的下标。
class _TpChainChapter {
  const _TpChainChapter({
    required this.chapter,
    required this.images,
    required this.globalIndex,
  });

  final ThirdPartyChapter chapter;
  final List<String> images;
  final int globalIndex;
}

class _ThirdPartyReaderPageState extends State<ThirdPartyReaderPage> {
  ThirdPartyComicSource? get _source =>
      ThirdPartySources.byKey(widget.sourceKey);

  final _user = UserManager();

  // 连续阅读链：跨话拼接图片，_chainIndex 指向当前所在章节
  List<_TpChainChapter> _chain = [];
  int _chainIndex = 0;
  List<String> _flat = [];
  bool _loadingNext = false;

  bool _loading = true;
  String? _error;
  bool _showToolbar = false;
  int _page = 1; // 全局图片页码（1-based）
  bool _isDraggingSlider = false;

  final PageController _pageController = PageController();
  final ScrollController _scrollController = ScrollController();
  Timer? _autoHideTimer;

  int get _indexSafe =>
      widget.initialIndex.clamp(0, widget.chapters.length - 1);

  ThirdPartyChapter get _chapter => _chain.isEmpty
      ? widget.chapters[_indexSafe]
      : _chain[_chainIndex].chapter;

  bool get _isPageMode => _user.readerMode == 1;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    _loadSingleChapter(_indexSafe, page: widget.initialPage);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // 记录本地浏览历史
    _recordHistory();
  }

  void _recordHistory() {
    final source = ThirdPartySources.byKey(widget.sourceKey);
    final chapter = widget.chapters[_indexSafe];
    LocalHistory.instance.add(
      LocalHistoryItem(
        pathWord: '${widget.sourceKey}:${widget.comicId}',
        name: widget.comicName,
        cover: '',
        sourceKey: widget.sourceKey,
        sourceName: source?.name ?? widget.sourceKey,
        chapterName: chapter.name,
        page: widget.initialPage,
        viewedAt: DateTime.now(),
      ),
    );
    // 漫屋吧登录后上报云端阅读记录。
    if (widget.sourceKey == 'manwaba' &&
        UserManager().isManwabaLoggedIn) {
      unawaited(
        ManwabaAuth.instance.recordHistory(widget.comicId, chapter.id),
      );
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _pageController.dispose();
    _scrollController.dispose();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  /// 合并链中所有图片为全局图片列表。
  void _rebuildFlat() {
    _flat = [for (final c in _chain) ...c.images];
  }

  /// 第 [ci] 章在全局图片列表中的起始索引（0-based）。
  int _chapterStart(int ci) {
    var s = 0;
    for (var i = 0; i < ci && i < _chain.length; i++) {
      s += _chain[i].images.length;
    }
    return s;
  }

  /// 整章加载：清空链，只保留 [globalIndex] 这一话。
  Future<void> _loadSingleChapter(int globalIndex, {int page = 1}) async {
    final source = _source;
    if (source == null) {
      setState(() {
        _loading = false;
        _error = '未知的漫源';
      });
      return;
    }
    final chapter = widget.chapters[globalIndex];
    setState(() {
      _loading = true;
      _error = null;
      _chain = [];
      _flat = [];
      _chainIndex = 0;
    });
    try {
      final images = await source.loadEp(widget.comicId, chapter.id);
      if (!mounted) return;
      setState(() {
        _chain = [
          _TpChainChapter(
            chapter: chapter,
            images: images,
            globalIndex: globalIndex,
          ),
        ];
        _rebuildFlat();
        _page = images.isEmpty ? 1 : page.clamp(1, images.length);
        _loading = false;
        if (images.isEmpty) _error = '本章暂无图片';
      });
      if (images.isNotEmpty && _isPageMode && _pageController.hasClients) {
        _pageController.jumpToPage(_page - 1);
      }
      // 连续阅读：整章加载后立即预载下一话
      if (_user.readerContinuousReading &&
          globalIndex < widget.chapters.length - 1) {
        unawaited(_appendNext());
      }
    } catch (e) {
      debugPrint('${source.key} 章节图片加载失败: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 连续阅读：在链尾追加下一话。
  Future<void> _appendNext() async {
    if (_loadingNext || _chain.isEmpty) return;
    final last = _chain.last;
    final nextGlobal = last.globalIndex + 1;
    if (nextGlobal >= widget.chapters.length) return;
    final source = _source;
    if (source == null) return;
    _loadingNext = true;
    try {
      final nextChapter = widget.chapters[nextGlobal];
      final images = await source.loadEp(widget.comicId, nextChapter.id);
      if (!mounted) return;
      if (images.isEmpty) {
        _loadingNext = false;
        return;
      }
      setState(() {
        _chain.add(
          _TpChainChapter(
            chapter: nextChapter,
            images: images,
            globalIndex: nextGlobal,
          ),
        );
        _rebuildFlat();
        _loadingNext = false;
      });
    } catch (_) {
      _loadingNext = false;
    }
  }

  /// 根据全局页码同步当前章节（用于顶部章节名与进度记录）。
  void _syncChapterFromPage(int page) {
    var acc = 0;
    for (var ci = 0; ci < _chain.length; ci++) {
      acc += _chain[ci].images.length;
      if (page <= acc) {
        if (ci != _chainIndex) {
          setState(() => _chainIndex = ci);
        }
        return;
      }
    }
  }

  void _toggleToolbar() {
    setState(() => _showToolbar = !_showToolbar);
    if (_showToolbar) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
      _autoHideTimer?.cancel();
      _autoHideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _showToolbar) {
          setState(() => _showToolbar = false);
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        }
      });
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  /// 整章切换上一话/下一话（基于当前所在章节）。
  Future<void> _switchChapter(int delta) async {
    final cur = _chain.isEmpty ? _indexSafe : _chain[_chainIndex].globalIndex;
    final next = cur + delta;
    if (next < 0 || next >= widget.chapters.length) return;
    await _loadSingleChapter(next);
  }

  void _goPage(int page) {
    if (!_isPageMode) {
      // 滚动模式：按比例估算滚动位置
      final max = _scrollController.hasClients
          ? _scrollController.position.maxScrollExtent
          : 0.0;
      final target = max == 0 || _flat.length <= 1
          ? 0.0
          : ((page - 1) / (_flat.length - 1)).clamp(0.0, 1.0) * max;
      _scrollController.jumpTo(target);
      return;
    }
    if (_pageController.hasClients) {
      _pageController.jumpToPage(page - 1);
    }
  }

  Future<void> _saveProgress() async {
    if (_chain.isEmpty) return;
    final start = _chapterStart(_chainIndex);
    final inChapterPage =
        (_page - start).clamp(1, _chain[_chainIndex].images.length);
    await ThirdPartyReadingProgress.save(
      sourceKey: widget.sourceKey,
      comicId: widget.comicId,
      chapterIndex: _chain[_chainIndex].globalIndex,
      page: inChapterPage,
      totalPages: _chain[_chainIndex].images.length,
      chapterName: _chain[_chainIndex].chapter.name,
    );
  }

  /// 图片页变化（翻页/滚动）时更新页码、同步章节并保存进度。
  void _onPageChanged(int page) {
    if (page == _page) return;
    setState(() => _page = page);
    _syncChapterFromPage(page);
    unawaited(_saveProgress());
    // 预加载后面8页图片
    unawaited(_preloadNextPages(page, count: 8));
    // 连续阅读：还剩 2 页时预加载下一话，翻到末尾时已就绪无缝衔接
    if (_user.readerContinuousReading &&
        page >= _flat.length - 2 &&
        _chain.isNotEmpty &&
        _chain.last.globalIndex < widget.chapters.length - 1) {
      unawaited(_appendNext());
    }
  }

  /// 预加载后面 N 页图片到内存缓存
  Future<void> _preloadNextPages(int currentPage, {int count = 8}) async {
    final source = _source;
    if (source == null) return;
    final start = currentPage; // currentPage 是1-based，后面的页从 currentPage 开始
    final end = (currentPage + count).clamp(0, _flat.length);
    for (var i = start; i < end; i++) {
      final url = _flat[i];
      final request = source.imageRequest(url);
      if (request == null) continue;
      try {
        final provider = ThirdPartyImageProvider(url, request);
        await provider.fetchBytes(); // 下载并缓存到内存
      } catch (_) {
        // 预加载失败忽略，显示时会重试
      }
    }
  }

  void _showSettings() {
    setState(() => _showToolbar = false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: false,
      isScrollControlled: true,
      builder: (_) => _TpReaderSettingsSheet(
        onChanged: () {
          if (!mounted) return;
          setState(() {});
          // 阅读模式切换后重建视图
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _flat.isEmpty) return;
            if (_isPageMode && _pageController.hasClients) {
              _pageController.jumpToPage(_page - 1);
            }
          });
        },
      ),
    );
  }

  void _showCatalog() {
    setState(() => _showToolbar = false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final currentGlobal =
        _chain.isEmpty ? _indexSafe : _chain[_chainIndex].globalIndex;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                AppLocalizations.of(sheetContext)!.chapterCommentsCatalog,
                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: widget.chapters.length,
                itemBuilder: (context, i) {
                  final ch = widget.chapters[i];
                  final isCurrent = i == currentGlobal;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isCurrent
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 18,
                      color: isCurrent ? cs.primary : cs.onSurfaceVariant,
                    ),
                    title: Text(
                      ch.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent ? cs.primary : null,
                        fontWeight: isCurrent ? FontWeight.w600 : null,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      if (i == currentGlobal) return;
                      _loadSingleChapter(i);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── 阅读内容区 ──
          Positioned.fill(
            child: _loading
                ? const Center(child: ExpressiveLoadingIndicator())
                : _error != null
                    ? _buildError()
                    : _buildContent(),
          ),
          // 调光（深色模式阅读设置）
          if (isDark && _user.readerDimming > 0 && !_loading)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: ReaderChrome.dimOverlay(_user.readerDimming),
                ),
              ),
            ),
          // 状态显示（时间/电量/网络/页码）
          if (_user.reader.statusOverlay && !_loading && _flat.isNotEmpty)
            Positioned(
              top: 0,
              right: 0,
              child: ReaderStatusOverlay(
                currentPage: _page,
                totalPages: _flat.length,
              ),
            ),
          // ── 顶部控制栏 ──
          _buildTopBar(),
          // ── 底部控制栏 ──
          if (!_loading && _flat.isNotEmpty) _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.broken_image_outlined,
            size: 48,
            color: ReaderChrome.onSurfaceFaint,
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: ReaderChrome.onSurfaceMuted),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => _loadSingleChapter(_indexSafe),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    // 点击画面任意位置切换控制栏
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleToolbar,
      child: _isPageMode ? _buildPageMode() : _buildScrollMode(),
    );
  }

  Widget _buildPageMode() {
    final direction = _user.readerScrollDirection; // 0 左→右 1 右→左 2 上→下
    final vertical = direction == 2;
    return PageView.builder(
      controller: _pageController,
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      reverse: direction == 1 && !vertical,
      itemCount: _flat.length,
      onPageChanged: (page) => _onPageChanged(page + 1),
      itemBuilder: (context, i) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 左右（或上下）1/3 区域点击翻页
          onTapDown: (d) => _handlePageModeTapAt(d.localPosition, i),
          child: Center(
            child: TpAwareImage(
              sourceKey: widget.sourceKey,
              url: _flat[i],
              fit: BoxFit.contain,
            ),
          ),
        );
      },
    );
  }

  void _handlePageModeTapAt(Offset pos, int i) {
    if (_showToolbar) return;
    final size = MediaQuery.of(context).size;
    final vertical = _user.readerScrollDirection == 2;
    final len = vertical ? size.height : size.width;
    final p = vertical ? pos.dy : pos.dx;
    if (p < len / 3) {
      if (i > 0) {
        _pageController.previousPage(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } else {
        // 链首向前：连续阅读时切上一话
        if (_user.readerContinuousReading) {
          _switchChapter(-1);
        }
      }
    } else if (p > len * 2 / 3) {
      if (i < _flat.length - 1) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } else {
        // 链尾向后：连续阅读时 onPageChanged 已触发自动追加
        if (!_user.readerContinuousReading) {
          _switchChapter(1);
        }
      }
    }
  }

  Widget _buildScrollMode() {
    return ListView.builder(
      controller: _scrollController,
      itemCount: _flat.length,
      itemBuilder: (context, i) {
        // 滚动接近末尾（剩 3 项）时预加载下一话（连续阅读）
        if (_user.readerContinuousReading &&
            i >= _flat.length - 3 &&
            _chain.isNotEmpty &&
            _chain.last.globalIndex < widget.chapters.length - 1) {
          unawaited(_appendNext());
        }
        return _ScrollPageImage(
          sourceKey: widget.sourceKey,
          url: _flat[i],
          isVisible: (visible) {
            if (visible && i + 1 != _page) _onPageChanged(i + 1);
          },
        );
      },
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_showToolbar,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 200),
          offset: Offset(0, _showToolbar ? 0 : -1),
          child: Container(
            color: ReaderChrome.surface,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back,
                        color: ReaderChrome.onSurface,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _chapter.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ReaderChrome.onSurface,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            widget.comicName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ReaderChrome.onSurfaceMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final hasPrev = _chainIndex > 0 || _chain[_chainIndex].globalIndex > 0;
    final hasNext =
        _chain[_chainIndex].globalIndex < widget.chapters.length - 1;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_showToolbar,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 200),
          offset: Offset(0, _showToolbar ? 0 : 1),
          child: Container(
            color: ReaderChrome.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 页码进度条
                    Row(
                      children: [
                        Text(
                          '$_page',
                          style: const TextStyle(
                            color: ReaderChrome.onSurfaceMuted,
                            fontSize: 12,
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 7,
                              ),
                              activeTrackColor:
                                  Theme.of(context).colorScheme.primary,
                              inactiveTrackColor: ReaderChrome.trackInactive,
                              thumbColor: Theme.of(context).colorScheme.primary,
                              overlayColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.2),
                            ),
                            child: Slider(
                              value: _page.toDouble().clamp(
                                1,
                                _flat.length.toDouble(),
                              ),
                              min: 1,
                              max: _flat.length.toDouble(),
                              divisions: _flat.length > 1
                                  ? _flat.length - 1
                                  : null,
                              onChangeStart: (_) => _isDraggingSlider = true,
                              onChangeEnd: (_) {
                                _isDraggingSlider = false;
                                unawaited(_saveProgress());
                              },
                              onChanged: (v) {
                                setState(() => _page = v.round());
                                _goPage(v.round());
                              },
                            ),
                          ),
                        ),
                        Text(
                          '${_flat.length}',
                          style: const TextStyle(
                            color: ReaderChrome.onSurfaceMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    // 操作行
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.skip_previous,
                            color: hasPrev
                                ? ReaderChrome.onSurface
                                : ReaderChrome.onSurfaceFaint,
                          ),
                          onPressed: hasPrev ? () => _switchChapter(-1) : null,
                          tooltip: '上一话',
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.list,
                            color: ReaderChrome.onSurface,
                          ),
                          onPressed: _showCatalog,
                          tooltip: AppLocalizations.of(
                            context,
                          )!.chapterCommentsCatalog,
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.settings,
                            color: ReaderChrome.onSurface,
                          ),
                          onPressed: _showSettings,
                          tooltip:
                              AppLocalizations.of(context)!.readerSettingsTitle,
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.skip_next,
                            color: hasNext
                                ? ReaderChrome.onSurface
                                : ReaderChrome.onSurfaceFaint,
                          ),
                          onPressed: hasNext ? () => _switchChapter(1) : null,
                          tooltip: '下一话',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 滚动模式下的单页图片：等比撑满宽度，首帧可见时上报页码。
class _ScrollPageImage extends StatefulWidget {
  final String sourceKey;
  final String url;
  final ValueChanged<bool> isVisible;

  const _ScrollPageImage({
    required this.sourceKey,
    required this.url,
    required this.isVisible,
  });

  @override
  State<_ScrollPageImage> createState() => _ScrollPageImageState();
}

class _ScrollPageImageState extends State<_ScrollPageImage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.isVisible(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return TpAwareImage(
      sourceKey: widget.sourceKey,
      url: widget.url,
      fit: BoxFit.fitWidth,
      loadingHeight: 320,
    );
  }
}

/// 第三方阅读器设置面板：与拷贝漫画阅读器共享同一套 UserManager 设置。
class _TpReaderSettingsSheet extends StatefulWidget {
  final VoidCallback onChanged;

  const _TpReaderSettingsSheet({required this.onChanged});

  @override
  State<_TpReaderSettingsSheet> createState() => _TpReaderSettingsSheetState();
}

class _TpReaderSettingsSheetState extends State<_TpReaderSettingsSheet> {
  final _user = UserManager();
  bool _isDraggingBrightness = false;

  Widget _sectionHeader(String title, ColorScheme cs, TextTheme tt) {
    final line = Divider(
      height: 1,
      color: cs.outlineVariant.withValues(alpha: 0.5),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Expanded(child: line),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              title,
              style: tt.labelSmall?.copyWith(
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(child: line),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isPageMode = _user.readerMode == 1;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: _isDraggingBrightness ? 0 : 1.0,
      child: Material(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  l10n.readerSettingsTitle,
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: AppSpacing.xl),
                // 阅读模式
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    segments: [
                      ButtonSegment(
                        value: 0,
                        icon: const Icon(Icons.view_day),
                        label: Text(l10n.readerScrollMode),
                      ),
                      ButtonSegment(
                        value: 1,
                        icon: const Icon(Icons.auto_stories),
                        label: Text(l10n.readerPageMode),
                      ),
                    ],
                    selected: {_user.readerMode},
                    onSelectionChanged: (v) {
                      _user.setReaderMode(v.first);
                      setState(() {});
                      widget.onChanged();
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                // 翻页方向（仅翻页模式生效）
                if (isPageMode) ...[
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      segments: [
                        ButtonSegment(
                          value: 0,
                          icon: const Icon(Icons.arrow_forward),
                          label: Text(l10n.readerLeftToRight),
                        ),
                        ButtonSegment(
                          value: 1,
                          icon: const Icon(Icons.arrow_back),
                          label: Text(l10n.readerRightToLeft),
                        ),
                        ButtonSegment(
                          value: 2,
                          icon: const Icon(Icons.arrow_downward),
                          label: Text(l10n.readerTopToBottom),
                        ),
                      ],
                      selected: {_user.readerScrollDirection},
                      onSelectionChanged: (v) {
                        _user.setReaderScrollDirection(v.first);
                        setState(() {});
                        widget.onChanged();
                      },
                    ),
                  ),
                ],
                // 连续阅读
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.readerContinuousReading),
                  subtitle: Text(l10n.readerContinuousReadingDesc),
                  value: _user.readerContinuousReading,
                  onChanged: (v) {
                    _user.setReaderContinuousReading(v);
                    setState(() {});
                    widget.onChanged();
                  },
                ),
                // 显示
                _sectionHeader(l10n.readerDisplaySection, cs, tt),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.readerStatusOverlay),
                  value: _user.reader.statusOverlay,
                  onChanged: (v) {
                    _user.reader.setStatusOverlay(v);
                    setState(() {});
                    widget.onChanged();
                  },
                ),
                if (isDark) ...[
                  Row(
                    children: [
                      const Icon(Icons.brightness_low, size: 18),
                      const SizedBox(width: AppSpacing.sm),
                      Text(l10n.readerDimming, style: tt.bodyMedium),
                      const Spacer(),
                      Text(
                        '${(_user.readerDimming * 100).round()}%',
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _user.readerDimming,
                    max: 0.7,
                    divisions: 14,
                    onChangeStart: (_) =>
                        setState(() => _isDraggingBrightness = true),
                    onChangeEnd: (_) =>
                        setState(() => _isDraggingBrightness = false),
                    onChanged: (v) {
                      _user.setReaderDimming(v);
                      setState(() {});
                      widget.onChanged();
                    },
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
