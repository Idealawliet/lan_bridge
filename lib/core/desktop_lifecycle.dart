import 'package:flutter/services.dart';

/// 原生窗口关闭只隐藏窗口；显式退出才要求 Dart 清理会话后销毁引擎。
class DesktopLifecycle {
  DesktopLifecycle(this.cleanup, {MethodChannel? channel})
      : channel = channel ?? const MethodChannel('lan_bridge/lifecycle');

  /// 由应用提供的异步清理入口，负责连接、输入捕获等资源。
  final Future<void> Function() cleanup;

  /// 与 Windows/macOS 托盘和退出处理交换消息的原生通道。
  final MethodChannel channel;
  // 保存正在进行的退出清理，让重复退出请求共享同一个结果。
  Future<void>? _quitting;

  /// 安装原生退出回调；引擎销毁前必须完成应用层资源释放。
  void install() {
    // 原生端在正式退出前调用 prepareQuit 并等待此处理器返回。
    channel.setMethodCallHandler((call) async {
      // 未实现的方法显式报错，避免原生端误以为请求已成功处理。
      if (call.method != 'prepareQuit') throw MissingPluginException();
      // 仅首次请求启动清理，防止同时关闭同一个套接字或系统输入钩子。
      final task = _quitting ??= cleanup();
      try {
        // 等清理完成再允许原生退出流程继续。
        await task;
      } catch (_) {
        // 清理失败时解除缓存，下一次退出请求可以重新尝试。
        _quitting = null;
        // 将原始错误传回原生调用方，不把清理失败当作成功退出。
        rethrow;
      }
    });
  }

  /// 更新系统托盘中的控制状态、网络描述和信号格数。
  Future<void> updateStatus(
      {required String control,
      required String signal,
      required int bars}) async {
    try {
      // 状态展示由原生端实现，Dart 只传递显示所需的数据。
      await channel.invokeMethod<void>('updateStatus', {
        'control': control,
        'signal': signal,
        'bars': bars,
      });
    } on MissingPluginException {
      // 测试环境或未实现托盘的平台可没有此接口，输入功能仍可继续运行。
    } on PlatformException {
      // 托盘显示失败不应阻断正在进行的键鼠转发。
    }
  }

  /// 移除回调，避免已销毁的应用对象继续收到原生退出请求。
  void dispose() => channel.setMethodCallHandler(null);

  /// 请求原生退出，由原生流程回调 prepareQuit 完成清理。
  Future<void> quit() => channel.invokeMethod<void>('quit');
}
