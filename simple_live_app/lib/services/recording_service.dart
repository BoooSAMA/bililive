import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_https_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class RecordingService extends GetxService {
  // ── Public reactive state (for UI to bind to) ──

  final RxBool isRecording = false.obs;
  final RxString duration = "00:00".obs;
  final RxString fileSize = "".obs;

  // ── Internal state ──

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

  // ── Callback configuration (set once by LiveRoomController) ──

  String Function()? _getUserName;
  Future<void> Function()? _onRefreshPlayUrl;
  List<String> Function()? _getPlayUrls;
  Map<String, String>? Function()? _getPlayHeaders;

  void configure({
    required String Function() getUserName,
    required Future<void> Function() onRefreshPlayUrl,
    required List<String> Function() getPlayUrls,
    required Map<String, String>? Function() getPlayHeaders,
  }) {
    _getUserName = getUserName;
    _onRefreshPlayUrl = onRefreshPlayUrl;
    _getPlayUrls = getPlayUrls;
    _getPlayHeaders = getPlayHeaders;
  }

  // ── Singleton accessor ──

  static RecordingService get instance => Get.find<RecordingService>();

  // ═══════════════════════════════════════════════════════════════════
  // Public API
  // ═══════════════════════════════════════════════════════════════════

  /// 切换录音状态
  void toggleRecording() async {
    if (isRecording.value) {
      // 停止录音（FFmpeg 取消回调中会显示带文件名和时长的详细提示）
      _stopRecording();
      return;
    }

    final playUrls = _getPlayUrls!();
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

  /// 取消录音（删除文件）
  void cancelRecording() {
    _discardRequested = true;
    _doCancelFfmpeg();
    SmartDialog.showToast("正在取消录音...");
  }

  /// 静默停止录音，不显示 toast（用于页面销毁时的资源清理）
  void forceStopRecording() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    if (_recordingSessionId != null) {
      FFmpegKit.cancel(_recordingSessionId);
      _recordingSessionId = null;
    }
    isRecording.value = false;
  }

  // ═══════════════════════════════════════════════════════════════════
  // Private implementation
  // ═══════════════════════════════════════════════════════════════════

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
          var testFile = File(
              '$preferredDir/.write_test_${DateTime.now().millisecondsSinceEpoch}');
          await testFile.writeAsString('test');
          await testFile.delete();
          return preferredDir;
        } catch (e) {
          Log.logPrint("自定义录音路径不可写($preferredDir): $e");
          SmartDialog.showToast(
              "存储权限不足：请在系统设置中允许「文件和媒体」权限，已使用默认目录");
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
    var fileName = "${_getUserName!()}_$timestamp.m4a";

    // 获取可写目录，确保路径无尾部斜杠
    var saveDir = await _getWritableSaveDir();
    var outputPath = "$saveDir/$fileName";

    Log.logPrint("录音保存路径: $outputPath");
    _startRecording(outputPath);
  }

  /// 构建FFmpeg参数列表
  List<String> _buildFFmpegArgs(String outputPath) {
    var args = <String>['-y'];

    final playHeaders = _getPlayHeaders!();

    // 显式设置 User-Agent（-headers 不会覆盖 FFmpeg 内置 UA，导致重复）
    if (playHeaders != null && playHeaders.containsKey('user-agent')) {
      args.addAll(['-user_agent', playHeaders['user-agent']!]);
    }

    // HTTP headers（排除 user-agent 避免重复）
    if (playHeaders != null && playHeaders.isNotEmpty) {
      var filteredHeaders = Map<String, String>.from(playHeaders);
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
    final playUrls = _getPlayUrls!();
    args.addAll(['-i', playUrls.first]);

    // 输出参数：流拷贝音频、不录制视频
    args.addAll(['-c:a', 'copy', '-vn']);
    args.addAll(['-f', 'mp4', outputPath]);

    return args;
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
        SmartDialog.showToast(
            "录音失败：存储权限不足\n${_formatRecordingSummary("已保存")}");
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
      await _onRefreshPlayUrl!();
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
    var userName = _getUserName!();

    var datePart =
        "${startTime.year}-${startTime.month.toString().padLeft(2, '0')}-${startTime.day.toString().padLeft(2, '0')}";
    var startPart =
        "${startTime.hour.toString().padLeft(2, '0')}-${startTime.minute.toString().padLeft(2, '0')}";
    var endPart =
        "${endTime.hour.toString().padLeft(2, '0')}-${endTime.minute.toString().padLeft(2, '0')}";

    var newFileName = "${userName}_${datePart}_${startPart}_$endPart.m4a";
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
    duration.value = "00:00";
    fileSize.value = "";
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _recordingSeconds++;
      var m = (_recordingSeconds ~/ 60).toString().padLeft(2, '0');
      var s = (_recordingSeconds % 60).toString().padLeft(2, '0');
      duration.value = "$m:$s";
      // 每秒同步更新文件大小（文件首次写入后才会显示）
      fileSize.value = _formatFileSize(_recordingOutputPath);
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
    var d = duration.value;
    var fs = _formatFileSize(_recordingOutputPath);
    var fileName = _formatRecordingFileName(_recordingOutputPath);
    return "$status $d · $fs · $fileName";
  }

  /// 停止录音（保存文件）
  void _stopRecording() {
    _discardRequested = false;
    _doCancelFfmpeg();
    SmartDialog.showToast("正在停止录音...");
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
}
