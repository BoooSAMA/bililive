import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_export_service.dart';
import 'package:simple_live_app/services/follow_service.dart';

class FollowUserController extends BasePageController<FollowUser> {
  /// 0:全部(分组) 1:直播中 2:未直播
  var filterMode = 0.obs;

  /// 分组：直播中的直播间
  var liveItems = <FollowUser>[].obs;

  /// 分组：未开播的直播间
  var notLiveItems = <FollowUser>[].obs;

  @override
  void onInit() {
    EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          refreshData();
        }
      },
    );
    // 监听数据源变化，自动刷新分组
    ever(FollowService.instance.liveList, (_) => filterData());
    ever(FollowService.instance.notLiveList, (_) => filterData());
    super.onInit();
  }

  @override
  void onReady() {
    refreshData();
    super.onReady();
  }

  @override
  Future refreshData() async {
    try {
      await FollowService.instance.loadData();
      filterData();
      pageEmpty.value = list.isEmpty;
      pageError.value = false;
    } catch (e) {
      handleError(e, showPageError: true);
    } finally {
      pageLoadding.value = false;
      easyRefreshController.finishRefresh();
      easyRefreshController.resetLoadState();
    }
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    // FollowUserController doesn't use paginated network fetch.
    // Data is loaded via FollowService.loadData() and filtered via filterData().
    return [];
  }

  /// 当前显示列表中的置顶直播间数量
  int get pinnedCount {
    final pinnedIds = AppSettingsController.instance.pinnedFollowIds;
    var count = 0;
    for (final item in list) {
      if (pinnedIds.contains(item.id)) count++;
    }
    return count;
  }

  void filterData() {
    // 先拷贝再赋值，避免遍历时 RxList 被并发修改
    List<FollowUser> source;
    switch (filterMode.value) {
      case 0: // 全部：分组展示
        liveItems.value = FollowService.instance.liveList.toList();
        notLiveItems.value = FollowService.instance.notLiveList.toList();
        source = [...liveItems, ...notLiveItems];
        break;
      case 1: // 仅直播中
        liveItems.value = FollowService.instance.liveList.toList();
        notLiveItems.value = [];
        source = liveItems.toList();
        break;
      case 2: // 仅未开播
        liveItems.value = [];
        notLiveItems.value = FollowService.instance.notLiveList.toList();
        source = notLiveItems.toList();
        break;
      default:
        liveItems.value = [];
        notLiveItems.value = [];
        source = [];
    }

    // 置顶排序：pinned 项排前面
    final pinnedIds = AppSettingsController.instance.pinnedFollowIds;

    void sortPinned(List<FollowUser> items) {
      items.sort((a, b) {
        final aPinned = pinnedIds.contains(a.id);
        final bPinned = pinnedIds.contains(b.id);
        if (aPinned && !bPinned) return -1;
        if (!aPinned && bPinned) return 1;
        return 0;
      });
    }

    sortPinned(source);
    sortPinned(liveItems);
    sortPinned(notLiveItems);

    list.assignAll(source);
  }

  void setFilterMode(int mode) {
    filterMode.value = mode;
    filterData();
  }

  void removeItem(FollowUser item) async {
    var result = await Utils.showAlertDialog(
      "确定要取消关注${item.userName}吗?",
      title: "取消关注",
    );
    if (!result) return;
    await FollowService.instance.removeFollow(item.id);
    refreshData();
  }

  void exportData() => FollowExportService.exportFollowData();

  void importData() => FollowExportService.importFollowData();
}
