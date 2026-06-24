import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';

class AutoExitService extends GetxService {
  static AutoExitService get instance => Get.find<AutoExitService>();

  final RxInt countdown = 60.obs;
  final RxInt autoExitMinutes = 60.obs;
  final RxBool delayAutoExit = false.obs;
  final RxBool autoExitEnable = false.obs;

  Timer? _timer;

  /// Called when countdown reaches zero.
  /// Return true to restart the timer (user chose to delay), false to exit.
  Future<bool> Function()? onExpired;

  /// Initialize auto-exit from AppSettingsController
  void init() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      start();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  /// Start or restart the countdown timer
  void start() {
    if (!autoExitEnable.value) {
      _timer?.cancel();
      return;
    }
    _timer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        _timer?.cancel();
        if (onExpired != null) {
          var delay = await onExpired!();
          if (delay) {
            delayAutoExit.value = true;
            start(); // restart timer
          } else {
            delayAutoExit.value = false;
          }
        }
      }
    });
  }

  /// Cancel the timer without changing enable state
  void cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
