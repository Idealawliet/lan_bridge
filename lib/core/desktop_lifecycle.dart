import 'package:flutter/services.dart';

/// Native window close hides the window. Only an explicit application quit
/// asks Dart to stop sessions before the engine is destroyed.
class DesktopLifecycle {
  DesktopLifecycle(this.cleanup, {MethodChannel? channel})
      : channel = channel ?? const MethodChannel('lan_bridge/lifecycle');
  final Future<void> Function() cleanup;
  final MethodChannel channel;
  Future<void>? _quitting;
  void install() {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'prepareQuit') throw MissingPluginException();
      final task = _quitting ??= cleanup();
      try {
        await task;
      } catch (_) {
        _quitting = null;
        rethrow;
      }
    });
  }

  Future<void> updateStatus(
      {required String control,
      required String signal,
      required int bars}) async {
    try {
      await channel.invokeMethod<void>('updateStatus', {
        'control': control,
        'signal': signal,
        'bars': bars,
      });
    } on MissingPluginException {
      // Tests and unsupported desktop platforms have no tray host.
    } on PlatformException {
      // Tray availability must never interrupt input forwarding.
    }
  }

  void dispose() => channel.setMethodCallHandler(null);
}
