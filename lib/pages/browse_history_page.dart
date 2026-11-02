import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/third_party/manwaba_auth.dart';
import '../api/third_party/third_party_source.dart';
import '../api/third_party/third_party_sources.dart';
import '../models/comic.dart' hide Theme;
import '../models/user_manager.dart';
import '../routing/app_router.dart';
import '../theme/app_spacing.dart';
import '../widgets/third_party_image.dart';

/// 浏览记录页面：登录漫屋吧后展示账号云端浏览记录。
class BrowseHistoryPage extends StatefulWidget {
  final WidgetBuilder loginPageBuilder; // 保留兼容，不再使用

  const BrowseHistoryPage({super.key, required this.loginPageBuilder});

  @override
  State<BrowseHistoryPage> createState() => _BrowseHistoryPageState();
}

class _BrowseHistoryPageState extends State<BrowseHistoryPage> {
  final _user = UserManager();
  final List<ManwabaHistoryItem> _items = [];
  bool _loading = true;
  int _page = 1;
  bool _hasNext = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _user.addListener(_onUserChanged);
    _load(reset: true);
  }

  @override
  void dispose() {
    _user.removeListener(_onUserChanged);
    super.dispose();
  }

  void _onUserChanged() {
    if (!mounted) return;
    if (_user.isManwabaLoggedIn) {
      _load(reset: true);
    } else {
      setState(() {
        _items.clear();
        _loading = false;
      });
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (!_user.isManwabaLoggedIn) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
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
      final result = await ManwabaAuth.instance.listHistory(
        page: _page,
        pageSize: 30,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(result.list);
        _hasNext = result.hasNext;
        if (result.hasNext) _page++;
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

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空浏览记录'),
        content: const Text('确定要清空所有浏览记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await ManwabaAuth.instance.clearHistory();
        await _load(reset: true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('清空失败：$e')),
          );
        }
      }
    }
  }

  Future<void> _removeItem(ManwabaHistoryItem item) async {
    try {
      await ManwabaAuth.instance.deleteHistory(item.id);
      if (!mounted) return;
      final targetId = item.id;
      setState(() => _items.removeWhere((ManwabaHistoryItem e) => e.id == targetId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$e')),
        );
      }
    }
  }

  void _openComic(ManwabaHistoryItem item) {
    final source = ThirdPartySources.byKey('manwaba');
    if (source == null) return;
    context.pushNamed(
      AppRoutes.comicDetail,
      pathParameters: {'pathWord': source.encodeComicId(item.comicId)},
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final loggedIn = _user.isManwabaLoggedIn;

    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览记录'),
        actions: [
          if (loggedIn && _items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空',
              onPressed: _clearHistory,
            ),
        ],
      ),
      body: !loggedIn
          ? _buildLoginPrompt(cs, tt)
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _buildError(cs, tt)
                  : _items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.history,
                                  size: 64,
                                  color: cs.onSurfaceVariant.withOpacity(0.5)),
                              const SizedBox(height: AppSpacing.lg),
                              Text('暂无浏览记录',
                                  style: tt.titleMedium
                                      ?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: () => _load(reset: true),
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              if (n.metrics.pixels >=
                                      n.metrics.maxScrollExtent - 200 &&
                                  !_loadingMore &&
                                  _hasNext) {
                                _load();
                              }
                              return false;
                            },
                            child: ListView.separated(
                              padding: const EdgeInsets.all(16),
                              itemCount: _items.length + (_hasNext ? 1 : 0),
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (ctx, i) {
                                if (i >= _items.length) {
                                  return const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(12),
                                      child: CircularProgressIndicator(),
                                    ),
                                  );
                                }
                                final item = _items[i];
                                return _HistoryCard(
                                  item: item,
                                  onTap: () => _openComic(item),
                                  onRemove: () => _removeItem(item),
                                );
                              },
                            ),
                          ),
                        ),
    );
  }

  Widget _buildLoginPrompt(ColorScheme cs, TextTheme tt) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 64, color: cs.onSurfaceVariant),
            const SizedBox(height: AppSpacing.lg),
            Text('登录后查看浏览记录',
                style: tt.titleMedium?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '浏览记录将与漫屋吧账号同步',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton(
              onPressed: () => context.pushNamed(AppRoutes.manwabaLogin),
              child: const Text('去登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(ColorScheme cs, TextTheme tt) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 48, color: cs.onSurfaceVariant),
          const SizedBox(height: AppSpacing.md),
          Text(_error!, style: tt.bodySmall),
          const SizedBox(height: AppSpacing.md),
          FilledButton.tonal(
            onPressed: () => _load(reset: true),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final ManwabaHistoryItem item;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _HistoryCard({
    required this.item,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 56,
                  height: 76,
                  child: item.cover.isEmpty
                      ? Container(
                          color: cs.surfaceContainerHighest,
                          child: Icon(Icons.book, color: cs.onSurfaceVariant),
                        )
                      : TpAwareImage(sourceKey: 'manwaba', url: item.cover),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: tt.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    if (item.chapterTitle != null &&
                        item.chapterTitle!.isNotEmpty)
                      Text(
                        '读到：${item.chapterTitle}',
                        style: tt.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      _formatTime(item.timestamp),
                      style: tt.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, size: 18, color: cs.onSurfaceVariant),
                onPressed: onRemove,
                tooltip: '移除',
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
