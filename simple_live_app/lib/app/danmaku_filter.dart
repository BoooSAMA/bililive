import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 弹幕关键词屏蔽过滤器
///
/// 根据用户在设置中配置的关键词列表，判断一条弹幕消息是否应被屏蔽。
/// 支持普通关键词匹配和正则表达式匹配。
class DanmakuFilter {
  /// 检查消息是否应被屏蔽。
  ///
  /// 返回 `true` 表示消息命中关键词，应被过滤掉。
  static bool shouldBlock(LiveMessage msg) {
    for (var keyword in AppSettingsController.instance.shieldList) {
      Pattern? pattern;
      if (Utils.isRegexFormat(keyword)) {
        var removedSlash = Utils.removeRegexFormat(keyword);
        try {
          pattern = RegExp(removedSlash);
        } catch (e) {
          Log.logPrint("关键词「$keyword」正则格式错误: $e");
        }
      } else {
        pattern = keyword;
      }
      if (pattern != null && msg.message.contains(pattern)) {
        Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
        return true;
      }
    }
    return false;
  }
}
