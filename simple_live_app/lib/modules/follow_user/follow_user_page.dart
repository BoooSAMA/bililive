import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';
import 'package:simple_live_app/widgets/status/app_error_widget.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';

class FollowUserPage extends GetView<FollowUserController> {
  const FollowUserPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var count = MediaQuery.of(context).size.width ~/ 500;
    if (count < 1) count = 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text("关注用户"),
        leading: Obx(
          () {
            final fs = FollowService.instance;
            if (fs.updating.value) {
              final progress = fs.loadProgress.value;
              return Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: progress > 0 ? progress : null,
                        strokeWidth: 2.5,
                      ),
                      if (progress > 0)
                        Text(
                          '${(progress * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            }
            return IconButton(
              onPressed: controller.refreshData,
              icon: const Icon(Icons.refresh),
            );
          },
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'export':
                  controller.exportData();
                  break;
                case 'import':
                  controller.importData();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'export',
                child: ListTile(
                  leading: Icon(Icons.upload_file),
                  title: Text('导出关注数据'),
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const PopupMenuItem(
                value: 'import',
                child: ListTile(
                  leading: Icon(Icons.file_download),
                  title: Text('导入关注数据'),
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Obx(
        () {
          if (controller.pageLoadding.value) {
            return const AppLoaddingWidget();
          }
          if (controller.pageError.value) {
            return AppErrorWidget(
              errorMsg: controller.errorMsg.value,
              onRefresh: () => controller.refreshData(),
            );
          }
          if (controller.pageEmpty.value) {
            return AppEmptyWidget(
              onRefresh: () => controller.refreshData(),
            );
          }
          return Column(
            children: [
              _buildFilterBar(context),
              Expanded(
                child: controller.filterMode.value == 0
                    ? _buildGroupedList(context)
                    : _buildSimpleList(context, count),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 筛选栏：全部 / 直播中 / 未开播
  Widget _buildFilterBar(BuildContext context) {
    final liveCount = FollowService.instance.liveList.length;
    final notLiveCount = FollowService.instance.notLiveList.length;
    final allCount = FollowService.instance.followList.length;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          _filterChip(context, '直播中', liveCount, 1),
          _filterChip(context, '未开播', notLiveCount, 2),
          _filterChip(context, '全部', allCount, 0),
        ],
      ),
    );
  }

  Widget _filterChip(
      BuildContext context, String label, int count, int mode) {
    final selected = controller.filterMode.value == mode;
    return Expanded(
      child: InkWell(
        onTap: () => controller.setFilterMode(mode),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            count > 0 ? '$label $count' : label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface.withAlpha(180),
            ),
          ),
        ),
      ),
    );
  }

  /// 分组列表：直播中 + 未开播 两个 section
  Widget _buildGroupedList(BuildContext context) {
    final liveItems = controller.liveItems;
    final notLiveItems = controller.notLiveItems;

    return CustomScrollView(
      slivers: [
        // 直播中 section
        if (liveItems.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _buildSectionHeader(
              context,
              '直播中',
              liveItems.length,
              icon: Icons.live_tv,
              color: Colors.green,
            ),
          ),
          _buildSliverList(liveItems),
        ],
        // 未开播 section
        if (notLiveItems.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _buildSectionHeader(
              context,
              '未开播',
              notLiveItems.length,
              icon: Icons.schedule,
              color: Colors.grey,
            ),
          ),
          _buildSliverList(notLiveItems),
        ],
        // 底部留白
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  /// 单一列表（直播中 或 未开播 筛选模式）
  Widget _buildSimpleList(BuildContext context, int crossAxisCount) {
    return MasonryGridView.count(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      itemCount: controller.list.length,
      itemBuilder: (_, i) {
        var item = controller.list[i];
        var site = Sites.allSites[item.siteId]!;
        return FollowUserItem(
          item: item,
          onRemove: () => controller.removeItem(item),
          onPinToggled: () => controller.filterData(),
          onTap: () {
            AppNavigator.toLiveRoomDetail(
              site: site,
              roomId: item.roomId,
            );
          },
        );
      },
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    );
  }

  /// 分组 section header
  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    int count, {
    IconData? icon,
    Color? color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(60),
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurface.withAlpha(180),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color?.withAlpha(30) ?? Colors.grey.withAlpha(30),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                color: color ?? Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 复用的 SliverList 构建
  Widget _buildSliverList(RxList<FollowUser> items) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          var item = items[i];
          var site = Sites.allSites[item.siteId]!;
          return FollowUserItem(
            item: item,
            onRemove: () => controller.removeItem(item),
            onPinToggled: () => controller.filterData(),
            onTap: () {
              AppNavigator.toLiveRoomDetail(
                site: site,
                roomId: item.roomId,
              );
            },
          );
        },
        childCount: items.length,
      ),
    );
  }
}
