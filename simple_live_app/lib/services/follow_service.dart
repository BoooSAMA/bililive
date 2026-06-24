import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/db_service.dart';

class FollowService extends GetxService {
  static FollowService get instance => Get.find<FollowService>();

  StreamSubscription<dynamic>? subscription;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 是否正在更新
  var updating = false.obs;

  /// 加载进度 0.0~1.0，供关注页显示百分比进度圈
  var loadProgress = 0.0.obs;

  /// 防重入
  bool _loading = false;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData();
    });
    super.onInit();
  }

  /// 加载关注列表并检查直播状态（并发加速版）
  Future<void> loadData() async {
    if (_loading) return;
    _loading = true;
    try {
      final users = DBService.instance.followBox.values.toList();
      followList.value = users;

      if (users.isEmpty) {
        liveList.value = [];
        notLiveList.value = [];
        return;
      }

      updating.value = true;
      loadProgress.value = 0.0;

      // 先全部初始化为"未开播"，让 UI 立即有内容可展示
      for (final user in users) {
        user.liveStatus.value = 1;
      }
      liveList.value = [];
      notLiveList.value = users.toList();

      final liveIds = <String>{};
      int completed = 0;
      const maxConcurrency = 5;

      // 分批并发检查直播状态
      for (var i = 0; i < users.length; i += maxConcurrency) {
        final end = (i + maxConcurrency > users.length)
            ? users.length
            : i + maxConcurrency;
        final batch = users.sublist(i, end);

        await Future.wait(batch.map((user) async {
          try {
            var siteInfo = Sites.allSites[user.siteId];
            if (siteInfo == null) return;
            var isLive =
                await siteInfo.liveSite.getLiveStatus(roomId: user.roomId);
            user.liveStatus.value = isLive ? 2 : 1;
            if (isLive) {
              liveIds.add(user.id);
            }
          } catch (e) {
            Log.logPrint(e);
            user.liveStatus.value = 0;
          } finally {
            completed++;
            loadProgress.value = completed / users.length;
          }
        }));

        // 每批完成后增量更新列表，实现流式展示
        _syncLists(users, liveIds);
      }

      updating.value = false;
    } finally {
      _loading = false;
    }
  }

  /// 根据 [liveIds] 重新分配 liveList / notLiveList
  void _syncLists(List<FollowUser> allUsers, Set<String> liveIds) {
    final live = <FollowUser>[];
    final notLive = <FollowUser>[];
    for (final user in allUsers) {
      if (liveIds.contains(user.id)) {
        live.add(user);
      } else {
        notLive.add(user);
      }
    }
    liveList.value = live;
    notLiveList.value = notLive;
  }

  /// 添加关注
  void addFollow(FollowUser follow) {
    DBService.instance.addFollow(follow);
    loadData();
  }

  /// 取消关注
  Future<void> removeFollow(String id) async {
    await DBService.instance.followBox.delete(id);
    loadData();
  }

  @override
  void onClose() {
    subscription?.cancel();
    super.onClose();
  }
}
