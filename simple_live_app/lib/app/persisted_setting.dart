import 'package:get/get.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// A reactive setting that automatically persists to LocalStorageService.
/// Behaves identically to Rx<T> for UI binding (Obx(), .value, etc.).
class PersistedSetting<T> extends Rx<T> {
  final String _key;

  PersistedSetting(this._key, T defaultValue) : super(defaultValue) {
    value = LocalStorageService.instance.getValue(_key, defaultValue);
  }

  @override
  set value(T e) {
    super.value = e;
    LocalStorageService.instance.setValue(_key, e);
  }
}
