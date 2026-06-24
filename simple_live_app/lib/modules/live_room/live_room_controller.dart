import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 录音状态
  var isRecording = false.obs;
  var recordingDuration = "00:00".obs;
  var recordingFileSize = "".obs;
  int? _recordingSessionId;
  Timer? _recordingTimer;
  int _recordingSeconds = 0;

  /// 录音自动重连状态
  int _recordingRetryCount = 0;
  static const int _maxRecordingRetries = 3;
  String _recordingOutputPath = "";
  String? _recordingLastError;
  bool _discardRequested = false;

  /// 录音开始时间（用于文件名中含结束时间的重命名）
  DateTime? _recordingStartTime;

  /// 直播间加载失败
  var loadError = false.obs;
  Error? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    superChats.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }

      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      messages.add(msg);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => chatScrollToBottom(),
      );
      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e) {
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e as Error;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  void getPlayUrl() async {
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    playUrls.value = playUrl.urls;
    playHeaders = playUrl.headers;
    currentLineIndex = 0;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    //重置错误次数
    mediaErrorRetryCount = 0;
    initPlaylist();
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  void initPlaylist() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    final mediaList = playUrls.map((url) {
      var finalUrl = url;
      if (AppSettingsController.instance.playerForceHttps.value) {
        finalUrl = finalUrl.replaceAll("http://", "https://");
      }
      return Media(finalUrl, httpHeaders: playHeaders);
    }).toList();

    // 初始化播放器并设置 ao 参数
    await initializePlayer();

    await player.open(Playlist(mediaList));
  }

  void setPlayer() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    await player.jump(currentLineIndex);
  }

  @override
  void mediaEnd() async {
    super.mediaEnd();
    if (mediaErrorRetryCount < 2) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    Log.d("播放结束");
    // 遍历线路，如果全部链接都断开就是直播结束了
    if (playUrls.length - 1 == currentLineIndex) {
      liveStatus.value = false;
    } else {
      changePlayLine(currentLineIndex + 1);

      //setPlayer();
    }
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    super.mediaEnd();
    if (mediaErrorRetryCount < 2) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
    } else {
      //currentLineIndex += 1;
      //setPlayer();
      changePlayLine(currentLineIndex + 1);
    }
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }



  /// 关注用户
  void followUser() {
    if (detail.value == null) return;
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) return;
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) return;
    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }



  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    try {
      await launchUrlString(
        "bilibili://live/${detail.value?.roomId}",
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(
        "https://live.bilibili.com/${detail.value?.roomId}",
        mode: LaunchMode.externalApplication,
      );
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 停止录音
    if (isRecording.value) {
      _stopRecording();
    }

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    superChats.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${error?.stackTrace}''');
    SmartDialog.showToast("已复制错误信息");
  }

  /// 切换录音状态
  void toggleRecording() async {
    if (isRecording.value) {
      // 停止录音（FFmpeg 取消回调中会显示带文件名和时长的详细提示）
      _stopRecording();
      return;
    }

    if (playUrls.isEmpty) {
      SmartDialog.showToast("没有可用的播放地址");
      return;
    }

    // 防误触：确认对话框（自定义按钮布局，RED圆形REC图标）
    // 检查是否已勾选"不再显示"
    var noConfirm = LocalStorageService.instance
        .getValue(LocalStorageService.kRecordingNoConfirm, false);
    if (noConfirm) {
      _startRecordingWithPath();
      return;
    }

    // 防误触：确认对话框
    var noConfirmAgain = false;
    var confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text("开始录音"),
        content: StatefulBuilder(
          builder: (context, setInnerState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("将录制当前直播间的音频并保存为 M4A 文件"),
              const SizedBox(height: 16),
              InkWell(
                onTap: () => setInnerState(
                    () => noConfirmAgain = !noConfirmAgain),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      noConfirmAgain
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 20,
                      color: noConfirmAgain
                          ? Get.theme.colorScheme.primary
                          : null,
                    ),
                    const SizedBox(width: 8),
                    const Text("不再显示", style: TextStyle(fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              var dir = await FilePicker.platform.getDirectoryPath();
              if (dir != null) {
                AppSettingsController.instance.setAudioSavePath(dir);
                SmartDialog.showToast("存储路径已更改");
              }
            },
            child: const Text("选择路径"),
          ),
          TextButton(
            onPressed: () async {
              try {
                await launchUrlString('package:com.xycz.simple_live',
                    mode: LaunchMode.externalApplication);
              } catch (e) {
                SmartDialog.showToast("无法打开系统设置，请手动前往设置→应用→Bililive→权限");
              }
            },
            child: const Text("授予存储权限"),
          ),
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              if (noConfirmAgain) {
                LocalStorageService.instance
                    .setValue(LocalStorageService.kRecordingNoConfirm, true);
              }
              Get.back(result: true);
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _startRecordingWithPath();
  }

  /// 获取可写的录音保存目录
  /// FFmpeg 是 native 进程，Android 11+ 分区存储下外部路径可能不可写，
  /// 需要验证 POSIX 写权限，不可写时回退到应用文档目录。
  Future<String> _getWritableSaveDir() async {
    var preferredDir = AppSettingsController.instance.audioSavePath.value;

    if (preferredDir.isNotEmpty) {
      // 移除尾部斜杠，规范化路径
      preferredDir = preferredDir.replaceAll(RegExp(r'/+$'), '');
      var dir = Directory(preferredDir);
      if (await dir.exists()) {
        // 验证 native 进程写入权限（创建临时文件再删除）
        try {
          var testFile = File('$preferredDir/.write_test_${DateTime.now().millisecondsSinceEpoch}');
          await testFile.writeAsString('test');
          await testFile.delete();
          return preferredDir;
        } catch (e) {
          Log.logPrint("自定义录音路径不可写($preferredDir): $e");
          SmartDialog.showToast("存储权限不足：请在系统设置中允许「文件和媒体」权限，已使用默认目录");
        }
      } else {
        Log.logPrint("自定义录音路径不存在: $preferredDir");
      }
    }

    // 回退到应用文档目录（始终可写）
    var dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  /// 获取保存路径并开始录音
  void _startRecordingWithPath() async {
    var now = DateTime.now();
    var timestamp =
        "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}"
        "_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}";
    var fileName = "${detail.value?.userName ?? "live"}_$timestamp.m4a";

    // 获取可写目录，确保路径无尾部斜杠
    var saveDir = await _getWritableSaveDir();
    var outputPath = "$saveDir/$fileName";

    Log.logPrint("录音保存路径: $outputPath");
    _startRecording(outputPath);
  }

  /// 构建FFmpeg参数列表
  List<String> _buildFFmpegArgs(String outputPath) {
    var args = <String>['-y'];

    // 显式设置 User-Agent（-headers 不会覆盖 FFmpeg 内置 UA，导致重复）
    if (playHeaders != null && playHeaders!.containsKey('user-agent')) {
      args.addAll(['-user_agent', playHeaders!['user-agent']!]);
    }

    // HTTP headers（排除 user-agent 避免重复）
    if (playHeaders != null && playHeaders!.isNotEmpty) {
      var filteredHeaders = Map<String, String>.from(playHeaders!);
      filteredHeaders.remove('user-agent');
      if (filteredHeaders.isNotEmpty) {
        var headerStr = filteredHeaders.entries
            .map((e) => '${e.key}: ${e.value}')
            .join('\r\n');
        args.addAll(['-headers', '$headerStr\r\n']);
      }
    }

    // 重连参数
    args.addAll([
      '-reconnect',
      '1',
      '-reconnect_streamed',
      '1',
      '-reconnect_at_eof',
      '1',
      '-reconnect_delay_max',
      '5',
      '-timeout',
      '10000000',
    ]);

    // 使用第一个播放地址（与播放器同源）
    args.addAll(['-i', playUrls.first]);

    // 输出参数：流拷贝音频、不录制视频
    args.addAll(['-c:a', 'copy', '-vn']);
    args.addAll(['-f', 'mp4', outputPath]);

    return args;
  }

  /// 刷新播放地址用于录音重连
  Future<void> _refreshPlayUrlForRecording() async {
    try {
      if (detail.value == null || currentQuality < 0) return;
      var playUrl = await site.liveSite
          .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
      if (playUrl.urls.isNotEmpty) {
        playUrls.value = playUrl.urls;
        playHeaders = playUrl.headers;
        Log.logPrint("录音刷新播放地址成功: ${playUrl.urls.length} 条");
      }
    } catch (e) {
      Log.logPrint("录音刷新播放地址失败: $e");
    }
  }

  /// 启动 FFmpeg 录音进程
  Future<void> _startFFmpegSessionInternal() async {
    var args = _buildFFmpegArgs(_recordingOutputPath);
    if (_recordingRetryCount == 0) {
      Log.logPrint("开始录音: ${args.join(' ')}");
    } else {
      Log.logPrint("录音重连(第$_recordingRetryCount次): ${args.join(' ')}");
    }

    var session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        var returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          Log.logPrint("录音成功完成");
          SmartDialog.showToast(_formatRecordingSummary("录音完成 ✓"));
          await _onRecordingFinished();
        } else if (ReturnCode.isCancel(returnCode)) {
          Log.logPrint("录音已取消");
          if (_discardRequested) {
            _discardRequested = false;
            // 用户要求取消（删除文件）
            try {
              var file = File(_recordingOutputPath);
              if (file.existsSync()) file.deleteSync();
            } catch (_) {}
            SmartDialog.showToast("录音已取消");
          } else {
            SmartDialog.showToast(_formatRecordingSummary("录音已停止 ⏹"));
          }
          await _onRecordingFinished();
        } else {
          var output = await session.getOutput();
          var failStack = await session.getFailStackTrace();
          _recordingLastError = output;
          Log.logPrint("录音失败, output: $output, failStack: $failStack");
          _scheduleRecordingRetry();
        }
      },
      (log) {
        Log.logPrint("FFmpeg: ${log.getMessage()}");
      },
    );
    _recordingSessionId = session.getSessionId();
  }

  /// 延时执行录音重连（避免在 FFmpeg 回调中递归）
  void _scheduleRecordingRetry() {
    if (_recordingRetryCount >= _maxRecordingRetries) {
      Log.logPrint("录音重连失败，已达最大重试次数");
      // 区分权限错误与其他错误
      var isPermissionError =
          _recordingLastError?.contains('Operation not permitted') == true;
      if (isPermissionError) {
        SmartDialog.showToast("录音失败：存储权限不足\n${_formatRecordingSummary("已保存")}");
      } else {
        SmartDialog.showToast(_formatRecordingSummary("录音中断 ✗"));
      }
      _recordingLastError = null;
      _onRecordingFinished();
      return;
    }

    _recordingRetryCount++;
    Log.logPrint(
        "录音重连: 第$_recordingRetryCount/$_maxRecordingRetries 次，2秒后重试");
    SmartDialog.showToast("录音断连，正在尝试重连...");

    Future.delayed(const Duration(seconds: 2), () async {
      if (!isRecording.value) return;
      await _refreshPlayUrlForRecording();
      await _startFFmpegSessionInternal();
    });
  }

  /// 录音结束时重命名文件，在文件名末尾追加结束时间（HH-MM）
  Future<void> _renameRecordingFile(DateTime startTime) async {
    if (_recordingOutputPath.isEmpty) return;
    var file = File(_recordingOutputPath);
    if (!await file.exists()) return;

    var dir = file.parent.path;
    var endTime = DateTime.now();
    var userName = detail.value?.userName ?? "live";

    var datePart =
        "${startTime.year}-${startTime.month.toString().padLeft(2, '0')}-${startTime.day.toString().padLeft(2, '0')}";
    var startPart =
        "${startTime.hour.toString().padLeft(2, '0')}-${startTime.minute.toString().padLeft(2, '0')}";
    var endPart =
        "${endTime.hour.toString().padLeft(2, '0')}-${endTime.minute.toString().padLeft(2, '0')}";

    var newFileName = "${userName}_${datePart}_${startPart}_${endPart}.m4a";
    var newPath = "$dir/$newFileName";

    try {
      await file.rename(newPath);
      _recordingOutputPath = newPath;
      Log.d("录音文件重命名: $newFileName");
    } catch (e) {
      Log.d("录音文件重命名失败: $e");
    }
  }

  /// 清理录音状态
  Future<void> _onRecordingFinished() async {
    if (!_discardRequested && _recordingStartTime != null) {
      await _renameRecordingFile(_recordingStartTime!);
    }
    _recordingStartTime = null;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    isRecording.value = false;
    _recordingSessionId = null;
  }

  /// 开始录音
  void _startRecording(String outputPath) async {
    _recordingOutputPath = outputPath;
    _recordingStartTime = DateTime.now();
    _discardRequested = false;
    _recordingRetryCount = 0;

    await _startFFmpegSessionInternal();

    isRecording.value = true;
    _recordingSeconds = 0;
    recordingDuration.value = "00:00";
    recordingFileSize.value = "";
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _recordingSeconds++;
      var m = (_recordingSeconds ~/ 60).toString().padLeft(2, '0');
      var s = (_recordingSeconds % 60).toString().padLeft(2, '0');
      recordingDuration.value = "$m:$s";
      // 每秒同步更新文件大小（文件首次写入后才会显示）
      recordingFileSize.value = _formatFileSize(_recordingOutputPath);
    });
  }

  /// 取出路径中的文件名
  String _formatRecordingFileName(String path) {
    try {
      return path.split('/').last;
    } catch (_) {
      return path;
    }
  }

  /// 格式化文件大小（短格式：k / m / g，一位小数）
  String _formatFileSize(String path) {
    try {
      var file = File(path);
      if (file.existsSync()) {
        var bytes = file.lengthSync();
        if (bytes < 1024) return "${bytes}B";
        if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)}k";
        if (bytes < 1024 * 1024 * 1024) {
          return "${(bytes / (1024 * 1024)).toStringAsFixed(1)}m";
        }
        return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}g";
      }
    } catch (_) {
      // 文件可能尚不存在（FFmpeg 未写入任何数据即失败）
    }
    return "0B";
  }

  /// 格式化录音完成提示摘要
  String _formatRecordingSummary(String status) {
    var duration = recordingDuration.value;
    var fileSize = _formatFileSize(_recordingOutputPath);
    var fileName = _formatRecordingFileName(_recordingOutputPath);
    return "$status $duration · $fileSize · $fileName";
  }

  /// 停止录音（保存文件）
  void _stopRecording() {
    _discardRequested = false;
    _doCancelFfmpeg();
    SmartDialog.showToast("正在停止录音...");
  }

  /// 取消录音（删除文件）
  void cancelRecording() {
    _discardRequested = true;
    _doCancelFfmpeg();
    SmartDialog.showToast("正在取消录音...");
  }

  /// 取消 FFmpeg 进程并清理定时器
  void _doCancelFfmpeg() {
    if (_recordingSessionId != null) {
      FFmpegKit.cancel(_recordingSessionId);
      _recordingSessionId = null;
    }
    _recordingTimer?.cancel();
    _recordingTimer = null;
    isRecording.value = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    _recordingTimer?.cancel();
    if (_recordingSessionId != null) {
      FFmpegKit.cancel(_recordingSessionId);
      _recordingSessionId = null;
    }
    super.onClose();
  }
}
