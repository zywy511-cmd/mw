import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

import '../api/third_party/manwaba_auth.dart';
import '../api/third_party/third_party_source.dart';
import '../api/third_party/third_party_sources.dart';
import '../models/comic.dart' hide Theme;
import '../models/user_manager.dart';
import '../routing/app_router.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/local_favorites.dart';
import '../utils/third_party_reading_progress.dart';
import '../widgets/third_party_image.dart';
import 'third_party_reader_page.dart';

/// 第三方漫源（漫屋3/漫屋吧）详情页：标题/封面/作者/状态/简介 + 章节列表。
/// 章节按阅读顺序正序展示（第一话在最上），顶部提供「开始/继续阅读」。
class ThirdPartyComicDetailPage extends StatefulWidget {
  final String pathWord; // 形如 waman3:123456
  final Comic? initialComic;

  const ThirdPartyComicDetailPage({
    super.key,
    required this.pathWord,
    this.initialComic,
  });

  @override
  State<ThirdPartyComicDetailPage> createState() =>
      _ThirdPartyComicDetailPageState();
}

class _ThirdPartyComicDetailPageState extends State<ThirdPartyComicDetailPage> {
  ThirdPartyComicSource? get _source {
    final key = ThirdPartyComicSource.sourceKeyOfPathWord(widget.pathWord);
    return key == null ? null : ThirdPartySources.byKey(key);
  }

  String get _comicId =>
      ThirdPartyComicSource.comicIdOfPathWord(widget.pathWord);

  ThirdPartyComicDetail? _detail;
  bool _loading = true;
  String? _error;
  ThirdPartyProgressRecord? _progress;
  bool _isFavorited = false;

  @override
  void initState() {
    super.initState();
    _load();
    _checkFavorite();
  }

  Future<void> _checkFavorite() async {
    final user = UserManager();
    if (user.isManwabaLoggedIn && _source?.key == 'manwaba') {
      try {
        final fav = await ManwabaAuth.instance.checkFavorite(_comicId);
        if (!mounted) return;
        setState(() => _isFavorited = fav);
        return;
      } catch (_) {
        // 失败时回退本地状态
      }
    }
    final fav = await LocalFavorites.instance.isFavorite(widget.pathWord);
    if (!mounted) return;
    setState(() => _isFavorited = fav);
  }

  Future<void> _toggleFavorite() async {
    final user = UserManager();
    // 未登录：跳转漫屋吧登录页。
    if (!user.isManwabaLoggedIn) {
      final logged = await context.pushNamed<bool>(AppRoutes.manwabaLogin);
      if (logged == true) {
        _checkFavorite();
      }
      return;
    }
    if (_source?.key != 'manwaba') return;

    final wasFav = _isFavorited;
    // 乐观更新
    setState(() => _isFavorited = !wasFav);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (wasFav) {
        await ManwabaAuth.instance.deleteFavorite(_comicId);
        messenger.showSnackBar(const SnackBar(content: Text('已取消收藏')));
      } else {
        await ManwabaAuth.instance.addFavorite(_comicId);
        messenger.showSnackBar(const SnackBar(content: Text('已加入收藏')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isFavorited = wasFav);
      messenger.showSnackBar(SnackBar(content: Text('操作失败：$e')));
    }
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) {
      setState(() {
        _loading = false;
        _error = '未知的漫源';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await source.loadInfo(_comicId);
      final progress = await ThirdPartyReadingProgress.read(
        source.key,
        _comicId,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _progress = progress;
        _loading = false;
      });
    } catch (e) {
      debugPrint('${source.key} 详情加载失败: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openReader(
    List<ThirdPartyChapter> chapters,
    int index, {
    int page = 1,
  }) async {
    final source = _source;
    if (source == null || chapters.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ThirdPartyReaderPage(
          sourceKey: source.key,
          comicId: _comicId,
          comicName: _detail?.title ?? widget.initialComic?.name ?? '',
          chapters: chapters,
          initialIndex: index,
          initialPage: page,
        ),
      ),
    );
    // 从阅读器返回后刷新本地进度（断点续读入口随之更新）
    if (!mounted) return;
    final progress = await ThirdPartyReadingProgress.read(
      source.key,
      _comicId,
    );
    if (!mounted) return;
    setState(() => _progress = progress);
  }

  /// 点「开始/继续阅读」：有进度从断点继续，否则从第一话开始。
  Future<void> _openPrimaryReader() async {
    final detail = _detail;
    if (detail == null || detail.chapters.isEmpty) return;
    final p = _progress;
    final index = (p != null && p.chapterIndex < detail.chapters.length)
        ? p.chapterIndex
        : 0;
    final page = (p != null && p.chapterIndex == index) ? p.page : 1;
    await _openReader(detail.chapters, index, page: page);
  }

  /// 右下角「继续阅读」FAB 文案（对齐拷贝/热辣样式）。
  String _continueReadingLabel() {
    final p = _progress;
    if (p == null) return '开始阅读';
    final name = p.chapterName.length > 10
        ? '${p.chapterName.substring(0, 10)}…'
        : p.chapterName;
    if (p.totalPages > 1) return '$name · ${p.page}/${p.totalPages}';
    return name;
  }

  /// 右下角 FAB：仅在有阅读进度时显示。
  Widget _buildContinueFab() {
    final hasProgress = _progress != null &&
        _detail != null &&
        _progress!.chapterIndex < _detail!.chapters.length;
    if (!hasProgress) return const SizedBox.shrink();
    return Positioned(
      right: 16,
      bottom: 16,
      child: FloatingActionButton.extended(
        heroTag: 'tp_continue_reading',
        onPressed: _openPrimaryReader,
        icon: const Icon(Icons.play_arrow, size: 20),
        label: Text(
          _continueReadingLabel(),
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final source = _source;

    return Scaffold(
      appBar: AppBar(
        title: Text(_detail?.title ?? source?.name ?? ''),
        actions: [
          IconButton(
            icon: Icon(
              _isFavorited ? Icons.favorite : Icons.favorite_border,
              color: _isFavorited ? Colors.red : null,
            ),
            tooltip: _isFavorited ? '取消收藏' : '收藏',
            onPressed: _loading ? null : _toggleFavorite,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: ExpressiveLoadingIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cloud_off,
                        size: 48,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(_error!, style: tt.bodySmall),
                      const SizedBox(height: AppSpacing.md),
                      FilledButton.tonal(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    _buildContent(cs, tt),
                    _buildContinueFab(),
                  ],
                ),
    );
  }

  Widget _buildContent(ColorScheme cs, TextTheme tt) {
    final detail = _detail!;
    final cover = detail.cover.isNotEmpty
        ? detail.cover
        : (widget.initialComic?.cover ?? '');
    // 章节按阅读顺序正序展示：第一话在最上
    final chapters = detail.chapters;
    final hasProgress =
        _progress != null && _progress!.chapterIndex < chapters.length;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: AppRadius.mdR,
                  child: SizedBox(
                    width: 110,
                    height: 150,
                    child: TpAwareImage(
                      sourceKey: _source?.key,
                      url: cover,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        detail.title,
                        style: tt.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      if (detail.authors.isNotEmpty)
                        Text(
                          '作者：${detail.authors.join(' / ')}',
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      if (detail.statusDisplay != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          '状态：${detail.statusDisplay}',
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (detail.updateTime != null &&
                          detail.updateTime!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '更新：${detail.updateTime}',
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (detail.tags.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: detail.tags
                              .take(6)
                              .map(
                                (t) => Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cs.secondaryContainer,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    t,
                                    style: tt.labelSmall?.copyWith(
                                      color: cs.onSecondaryContainer,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (detail.description.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                detail.description,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
        // ── 开始/继续阅读：放在章节列表最上方（第一话上面）──
        if (chapters.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _openPrimaryReader,
                      icon: Icon(
                        hasProgress ? Icons.history : Icons.play_arrow,
                      ),
                      label: Text(
                        hasProgress
                            ? '继续阅读：${_progress!.chapterName}'
                                '${_progress!.page > 1 ? ' · 第${_progress!.page}页' : ''}'
                            : '开始阅读（第一话）',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => context.pushNamed(
                        AppRoutes.manwabaComments,
                        pathParameters: {'comicId': _comicId},
                      ),
                      icon: const Icon(Icons.comment_outlined, size: 18),
                      label: const Text('评论区'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (chapters.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.format_list_numbered, size: 18, color: cs.primary),
                  const SizedBox(width: 6),
                  Text(
                    '章节列表（共 ${chapters.length} 话）',
                    style: tt.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        if (chapters.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList.separated(
              itemCount: chapters.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                final chapter = chapters[i];
                final isProgressChapter = hasProgress &&
                    _progress!.chapterIndex == i;
                return Material(
                  color: cs.surfaceContainerLow,
                  borderRadius: AppRadius.mdR,
                  child: InkWell(
                    borderRadius: AppRadius.mdR,
                    onTap: () => _openReader(chapters, i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isProgressChapter
                                ? Icons.play_circle_fill
                                : Icons.menu_book_outlined,
                            size: 18,
                            color: isProgressChapter
                                ? cs.primary
                                : cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              chapter.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.bodyMedium?.copyWith(
                                color: isProgressChapter ? cs.primary : null,
                                fontWeight: isProgressChapter
                                    ? FontWeight.w600
                                    : null,
                              ),
                            ),
                          ),
                          if (isProgressChapter &&
                              _progress!.page > 1) ...[
                            Text(
                              '读到第${_progress!.page}页',
                              style: tt.labelSmall?.copyWith(
                                color: cs.primary,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Icon(
                            Icons.chevron_right,
                            size: 20,
                            color: cs.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        if (chapters.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.inbox_outlined,
                    size: 56,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text('暂无章节', style: tt.bodyMedium),
                ],
              ),
            ),
          ),
      ],
    );
  }
}


class ManwabaCommentsPage extends StatefulWidget {
  final String comicId;
  const ManwabaCommentsPage({super.key, required this.comicId});

  @override
  State<ManwabaCommentsPage> createState() => _ManwabaCommentsPageState();
}

class _ManwabaCommentsPageState extends State<ManwabaCommentsPage> {
  final _user = UserManager();
  final _inputCtrl = TextEditingController();
  final List<ManwabaComment> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _posting = false;
  int _page = 1;
  int _total = 0;
  bool _hasNext = true;
  String _sort = 'hot';
  String? _error;

  @override
  void initState() {
    super.initState();
    _user.addListener(_onLoginChanged);
    _load(reset: true);
  }

  @override
  void dispose() {
    _user.removeListener(_onLoginChanged);
    _inputCtrl.dispose();
    super.dispose();
  }

  void _onLoginChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
        _items.clear();
      });
    } else {
      if (_loadingMore || !_hasNext) return;
      setState(() => _loadingMore = true);
    }
    try {
      final r = await ManwabaAuth.instance.listComments(
        comicId: widget.comicId,
        page: _page,
        pageSize: 20,
        sort: _sort,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(r.list);
        _total = r.total;
        _hasNext = r.hasNext;
        if (r.hasNext) _page++;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _submit() async {
    final content = _inputCtrl.text.trim();
    if (content.isEmpty) return;
    setState(() => _posting = true);
    try {
      await ManwabaAuth.instance.postComment(
        comicId: widget.comicId,
        content: content,
      );
      if (!mounted) return;
      _inputCtrl.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('评论成功')));
      await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('评论失败：$e')));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _like(ManwabaComment c) async {
    if (!_user.isManwabaLoggedIn) {
      context.pushNamed(AppRoutes.manwabaLogin);
      return;
    }
    try {
      await ManwabaAuth.instance.likeComment(c.id);
      if (!mounted) return;
      setState(() {
        final idx = _items.indexWhere((e) => e.id == c.id);
        if (idx >= 0) {
          final old = _items[idx];
          _items[idx] = ManwabaComment(
            id: old.id,
            content: old.content,
            createdAt: old.createdAt,
            likes: old.likes + 1,
            feedCount: old.feedCount,
            isLiked: true,
            isEssential: old.isEssential,
            pinnedAt: old.pinnedAt,
            parentId: old.parentId,
            chapterTitle: old.chapterTitle,
            userId: old.userId,
            username: old.username,
            avatar: old.avatar,
            level: old.level,
            replyToName: old.replyToName,
            replies: old.replies,
          );
        }
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final loggedIn = _user.isManwabaLoggedIn;

    return Scaffold(
      appBar: AppBar(
        title: Text('评论区${_total > 0 ? '（$_total）' : ''}'),
        actions: [
          TextButton(
            onPressed: () {
              _sort = _sort == 'hot' ? 'new' : 'hot';
              _load(reset: true);
            },
            child: Text(_sort == 'hot' ? '最热' : '最新'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Column(
                    children: [
                      Text(_error!, style: tt.bodySmall),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: () => _load(reset: true),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            else if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text('暂无评论，快来发表第一条评论',
                      style: tt.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                ),
              )
            else
              ..._items.map((c) => _CommentTile(
                    comment: c,
                    onLike: () => _like(c),
                  )),
            if (_hasNext)
              Center(
                child: _loadingMore
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(),
                      )
                    : TextButton(
                        onPressed: () => _load(),
                        child: const Text('加载更多'),
                      ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: loggedIn
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputCtrl,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: '写下你的评论…',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _posting ? null : _submit,
                      icon: _posting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            )
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => context.pushNamed(AppRoutes.manwabaLogin),
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('登录后发表评论'),
                  ),
                ),
              ),
            ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  final ManwabaComment comment;
  final VoidCallback onLike;
  const _CommentTile({required this.comment, required this.onLike});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: cs.primaryContainer,
                child: Text(
                  comment.username.isNotEmpty
                      ? comment.username.substring(0, 1)
                      : '漫',
                  style: tt.bodySmall?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            comment.username,
                            style: tt.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: cs.secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Lv.${comment.level}',
                            style: tt.labelSmall
                                ?.copyWith(color: cs.onSecondaryContainer),
                          ),
                        ),
                        if (comment.isPinned)
                          Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: cs.errorContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('置顶',
                                style: tt.labelSmall
                                    ?.copyWith(color: cs.onErrorContainer)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      comment.createdAt,
                      style: tt.labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onLike,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      Icon(
                        comment.isLiked
                            ? Icons.favorite
                            : Icons.favorite_border,
                        size: 16,
                        color: comment.isLiked ? cs.primary : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        comment.likes > 0 ? '${comment.likes}' : '赞',
                        style: tt.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(comment.content, style: tt.bodyMedium),
          if (comment.chapterTitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '谈及：${comment.chapterTitle}',
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          // 回复列表
          if (comment.replies.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: comment.replies
                    .map((r) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: RichText(
                            text: TextSpan(
                              style: tt.bodySmall,
                              children: [
                                TextSpan(
                                  text: r.username,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: cs.primary,
                                  ),
                                ),
                                if (r.replyToName != null &&
                                    r.replyToName!.isNotEmpty) ...[
                                  const TextSpan(text: ' 回复 '),
                                  TextSpan(
                                    text: r.replyToName,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: cs.primary,
                                    ),
                                  ),
                                ],
                                TextSpan(text: '：${r.content}'),
                              ],
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}
