/// Practical next steps for known connection failures. Keep the original
/// error visible so an unrecognized cause is never misrepresented.
String connectionAdvice(String error) {
  final value = error.toLowerCase();
  if (value.contains('版本不一致')) {
    return '请在两台电脑的设置中安装相同版本，然后重新连接。';
  }
  if (value.contains('pin')) {
    return '请核对客户端当前显示的 6 位 PIN 码，并重新输入。';
  }
  if (value.contains('权限') || value.contains('permission')) {
    return '请检查系统的辅助功能和输入监控权限，然后重新启动应用。';
  }
  if (value.contains('超时') ||
      value.contains('timeout') ||
      value.contains('refused') ||
      value.contains('socket')) {
    return '请确认两台电脑位于同一局域网、客户端正在运行，并检查防火墙和连接地址。';
  }
  return '请检查两台电脑的连接状态和网络后重试；如仍失败，请记录上方错误信息。';
}
