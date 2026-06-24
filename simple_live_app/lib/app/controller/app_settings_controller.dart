import 'dart:convert';
import 'dart:io';

import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/persisted_setting.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/category/custom_category_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

class AppSettingsController extends GetxController {
  static AppSettingsController get instance =>
      Get.find<AppSettingsController>();

  /// 缩放模式
  final scaleMode = PersistedSetting<int>(
    LocalStorageService.kPlayerScaleMode,
    0,
  );

  final themeMode = PersistedSetting<int>(
    LocalStorageService.kThemeMode,
    0,
  );

  var firstRun = false;

  var homeDefaultCategory = Rxn<SavedSubCategory>();

  /// 收藏页置顶的直播间 ID 集合
  var pinnedFollowIds = <String>{}.obs;

  // --- Danmu settings ---
  final danmuSize = PersistedSetting<double>(
    LocalStorageService.kDanmuSize,
    16.0,
  );
  final danmuOpacity = PersistedSetting<double>(
    LocalStorageService.kDanmuOpacity,
    1.0,
  );
  final danmuArea = PersistedSetting<double>(
    LocalStorageService.kDanmuArea,
    0.8,
  );
  final danmuSpeed = PersistedSetting<double>(
    LocalStorageService.kDanmuSpeed,
    10.0,
  );
  final danmuEnable = PersistedSetting<bool>(
    LocalStorageService.kDanmuEnable,
    true,
  );
  final danmuStrokeWidth = PersistedSetting<double>(
    LocalStorageService.kDanmuStrokeWidth,
    2.0,
  );
  final danmuTopMargin = PersistedSetting<double>(
    LocalStorageService.kDanmuTopMargin,
    0.0,
  );
  final danmuBottomMargin = PersistedSetting<double>(
    LocalStorageService.kDanmuBottomMargin,
    0.0,
  );
  final danmuFontWeight = PersistedSetting<int>(
    LocalStorageService.kDanmuFontWeight,
    4,
  );

  // --- Player settings ---
  final hardwareDecode = PersistedSetting<bool>(
    LocalStorageService.kHardwareDecode,
    true,
  );
  final playerCompatMode = PersistedSetting<bool>(
    LocalStorageService.kPlayerCompatMode,
    false,
  );
  final playerBufferSize = PersistedSetting<int>(
    LocalStorageService.kPlayerBufferSize,
    32,
  );
  final playerAutoPause = PersistedSetting<bool>(
    LocalStorageService.kPlayerAutoPause,
    false,
  );
  final playerForceHttps = PersistedSetting<bool>(
    LocalStorageService.kPlayerForceHttps,
    false,
  );
  final autoFullScreen = PersistedSetting<bool>(
    LocalStorageService.kAutoFullScreen,
    false,
  );
  final playershowSuperChat = PersistedSetting<bool>(
    LocalStorageService.kPlayerShowSuperChat,
    true,
  );
  final playerVolume = PersistedSetting<double>(
    LocalStorageService.kPlayerVolume,
    100.0,
  );

  // --- Chat settings ---
  final chatTextSize = PersistedSetting<double>(
    LocalStorageService.kChatTextSize,
    14.0,
  );
  final chatTextGap = PersistedSetting<double>(
    LocalStorageService.kChatTextGap,
    4.0,
  );
  final chatBubbleStyle = PersistedSetting<bool>(
    LocalStorageService.kChatBubbleStyle,
    false,
  );

  // --- Quality settings ---
  final qualityLevel = PersistedSetting<int>(
    LocalStorageService.kQualityLevel,
    1,
  );
  final qualityLevelCellular = PersistedSetting<int>(
    LocalStorageService.kQualityLevelCellular,
    1,
  );

  // --- Auto exit settings ---
  final autoExitEnable = PersistedSetting<bool>(
    LocalStorageService.kAutoExitEnable,
    false,
  );
  final autoExitDuration = PersistedSetting<int>(
    LocalStorageService.kAutoExitDuration,
    60,
  );
  final roomAutoExitDuration = PersistedSetting<int>(
    LocalStorageService.kRoomAutoExitDuration,
    60,
  );

  // --- PIP settings ---
  final pipHideDanmu = PersistedSetting<bool>(
    LocalStorageService.kPIPHideDanmu,
    true,
  );

  // --- Style settings ---
  final styleColor = PersistedSetting<int>(
    LocalStorageService.kStyleColor,
    0xff3498db,
  );
  final isDynamic = PersistedSetting<bool>(
    LocalStorageService.kIsDynamic,
    false,
  );

  // --- Other settings ---
  final logEnable = PersistedSetting<bool>(
    LocalStorageService.kLogEnable,
    false,
  );
  final customPlayerOutput = PersistedSetting<bool>(
    LocalStorageService.kCustomPlayerOutput,
    false,
  );
  final videoHardwareDecoder = PersistedSetting<String>(
    LocalStorageService.kVideoHardwareDecoder,
    Platform.isAndroid ? "auto-safe" : "auto",
  );
  final audioSavePath = PersistedSetting<String>(
    LocalStorageService.kAudioSavePath,
    "",
  );

  // --- Manual settings (complex types or platform-dependent defaults) ---
  RxSet<String> shieldList = <String>{}.obs;
  RxList<String> siteSort = RxList<String>();
  RxList<String> homeSort = RxList<String>();

  var videoOutputDriver = "".obs;
  var audioOutputDriver = "".obs;

  @override
  void onInit() {
    firstRun = LocalStorageService.instance
        .getValue(LocalStorageService.kFirstRun, true);

    // ignore: invalid_use_of_protected_member
    shieldList.value = LocalStorageService.instance.shieldBox.values.toSet();

    if (logEnable.value) {
      Log.initWriter();
    }

    videoOutputDriver.value = LocalStorageService.instance.getValue(
      LocalStorageService.kVideoOutputDriver,
      Platform.isAndroid ? "gpu" : "libmpv",
    );

    audioOutputDriver.value = LocalStorageService.instance.getValue(
      LocalStorageService.kAudioOutputDriver,
      Platform.isAndroid
          ? "audiotrack"
          : Platform.isLinux
              ? "pulse"
              : Platform.isWindows
                  ? "wasapi"
                  : Platform.isIOS
                      ? "audiounit"
                      : Platform.isMacOS
                          ? "coreaudio"
                          : "sdl",
    );

    initSiteSort();
    initHomeSort();

    loadHomeDefaultCategory();

    loadPinnedFollowIds();

    super.onInit();
  }

  void initSiteSort() {
    var sort = LocalStorageService.instance
        .getValue(
          LocalStorageService.kSiteSort,
          Sites.allSites.keys.join(","),
        )
        .split(",");
    //如果数量与allSites的数量不一致，将缺失的添加上
    if (sort.length != Sites.allSites.length) {
      var keys = Sites.allSites.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        if (!sort.contains(keys[i])) {
          sort.add(keys[i]);
        }
      }
    }

    siteSort.value = sort;
  }

  void initHomeSort() {
    var sort = LocalStorageService.instance
        .getValue(
          LocalStorageService.kHomeSort,
          Constant.allHomePages.keys.join(","),
        )
        .split(",");
    //如果数量与allSites的数量不一致，将缺失的添加上
    if (sort.length != Constant.allHomePages.length) {
      var keys = Constant.allHomePages.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        if (!sort.contains(keys[i])) {
          sort.add(keys[i]);
        }
      }
    }

    homeSort.value = sort;
  }

  void loadHomeDefaultCategory() {
    final raw = LocalStorageService.instance
        .getValue<String>(LocalStorageService.kHomeDefaultCategory, '');
    if (raw.isEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      homeDefaultCategory.value = SavedSubCategory.fromJson(json);
    } catch (_) {
      homeDefaultCategory.value = null;
    }
  }

  void setHomeDefaultCategory(SavedSubCategory? cat) {
    homeDefaultCategory.value = cat;
    if (cat == null) {
      LocalStorageService.instance
          .removeValue(LocalStorageService.kHomeDefaultCategory);
    } else {
      final encoded = jsonEncode(cat.toJson());
      LocalStorageService.instance
          .setValue(LocalStorageService.kHomeDefaultCategory, encoded);
    }
  }

  /// 从本地存储加载置顶直播间 ID 列表
  void loadPinnedFollowIds() {
    final raw = LocalStorageService.instance
        .getValue<String>(LocalStorageService.kPinnedFollowUsers, '');
    if (raw.isEmpty) return;
    try {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      final ids = decoded.cast<String>().toSet();
      // ignore: invalid_use_of_protected_member
      pinnedFollowIds.value = ids;
    } catch (_) {
      // ignore: invalid_use_of_protected_member
      pinnedFollowIds.value = {};
    }
  }

  /// 保存置顶直播间 ID 列表到本地存储
  Future<void> savePinnedFollowIds() async {
    final encoded = jsonEncode(pinnedFollowIds.toList());
    await LocalStorageService.instance
        .setValue(LocalStorageService.kPinnedFollowUsers, encoded);
  }

  /// 判断直播间是否被置顶
  bool isFollowPinned(String id) => pinnedFollowIds.contains(id);

  /// 切换置顶状态
  Future<void> toggleFollowPin(String id) async {
    if (pinnedFollowIds.contains(id)) {
      pinnedFollowIds.remove(id);
    } else {
      pinnedFollowIds.add(id);
    }
    await savePinnedFollowIds();
  }

  void setNoFirstRun() {
    LocalStorageService.instance.setValue(LocalStorageService.kFirstRun, false);
  }

  void changeTheme() {
    Get.dialog(
      RadioGroup(
        groupValue: themeMode.value,
        onChanged: (e) {
          Get.back();
          setTheme(e ?? 0);
        },
        child: const SimpleDialog(
          title: Text("设置主题"),
          children: [
            RadioListTile<int>(
              title: Text("跟随系统"),
              value: 0,
            ),
            RadioListTile<int>(
              title: Text("浅色模式"),
              value: 1,
            ),
            RadioListTile<int>(
              title: Text("深色模式"),
              value: 2,
            ),
          ],
        ),
      ),
    );
  }

  void setTheme(int i) {
    themeMode.value = i;
    Get.changeThemeMode(ThemeMode.values[i]);
  }

  // --- Shield list (manual, uses Hive Box directly) ---
  void addShieldList(String e) {
    shieldList.add(e);
    LocalStorageService.instance.shieldBox.put(e, e);
  }

  void removeShieldList(String e) {
    shieldList.remove(e);
    LocalStorageService.instance.shieldBox.delete(e);
  }

  Future clearShieldList() async {
    shieldList.clear();
    await LocalStorageService.instance.shieldBox.clear();
  }

  // --- Site/Home sort (manual, uses join serialization) ---
  void setSiteSort(List<String> e) {
    siteSort.value = e;
    LocalStorageService.instance.setValue(
      LocalStorageService.kSiteSort,
      siteSort.join(","),
    );
  }

  void setHomeSort(List<String> e) {
    homeSort.value = e;
    LocalStorageService.instance.setValue(
      LocalStorageService.kHomeSort,
      homeSort.join(","),
    );
  }

  // --- Audio save path (has path normalization) ---
  void setAudioSavePath(String e) {
    var normalized = e.endsWith('/') ? e : '$e/';
    audioSavePath.value = normalized;
  }

  // --- Manual setters for video/audio output drivers (kept manual) ---
  void setVideoOutputDriver(String e) {
    videoOutputDriver.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kVideoOutputDriver, e);
  }

  void setAudioOutputDriver(String e) {
    audioOutputDriver.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kAudioOutputDriver, e);
  }

  // --- Persisted setting setters (persistence handled automatically) ---

  // Danmu
  void setDanmuSize(double e) => danmuSize.value = e;
  void setDanmuOpacity(double e) => danmuOpacity.value = e;
  void setDanmuArea(double e) => danmuArea.value = e;
  void setDanmuSpeed(double e) => danmuSpeed.value = e;
  void setDanmuEnable(bool e) => danmuEnable.value = e;
  void setDanmuStrokeWidth(double e) => danmuStrokeWidth.value = e;
  void setDanmuTopMargin(double e) => danmuTopMargin.value = e;
  void setDanmuBottomMargin(double e) => danmuBottomMargin.value = e;
  void setDanmuFontWeight(int e) => danmuFontWeight.value = e;

  // Player
  void setHardwareDecode(bool e) => hardwareDecode.value = e;
  void setPlayerCompatMode(bool e) => playerCompatMode.value = e;
  void setPlayerBufferSize(int e) => playerBufferSize.value = e;
  void setPlayerAutoPause(bool e) => playerAutoPause.value = e;
  void setPlayerForceHttps(bool e) => playerForceHttps.value = e;
  void setAutoFullScreen(bool e) => autoFullScreen.value = e;
  void setPlayerShowSuperChat(bool e) => playershowSuperChat.value = e;
  void setPlayerVolume(double value) => playerVolume.value = value;
  void setScaleMode(int value) => scaleMode.value = value;

  // Chat
  void setChatTextSize(double e) => chatTextSize.value = e;
  void setChatTextGap(double e) => chatTextGap.value = e;
  void setChatBubbleStyle(bool e) => chatBubbleStyle.value = e;

  // Quality
  void setQualityLevel(int level) => qualityLevel.value = level;
  void setQualityLevelCellular(int level) => qualityLevelCellular.value = level;

  // Auto exit
  void setAutoExitEnable(bool e) => autoExitEnable.value = e;
  void setAutoExitDuration(int e) => autoExitDuration.value = e;
  void setRoomAutoExitDuration(int e) => roomAutoExitDuration.value = e;

  // PIP
  void setPIPHideDanmu(bool e) => pipHideDanmu.value = e;

  // Style
  void setStyleColor(int e) => styleColor.value = e;
  void setIsDynamic(bool e) => isDynamic.value = e;

  // Other
  void setLogEnable(bool e) => logEnable.value = e;
  void setCustomPlayerOutput(bool e) => customPlayerOutput.value = e;
  void setVideoHardwareDecoder(String e) => videoHardwareDecoder.value = e;
}
