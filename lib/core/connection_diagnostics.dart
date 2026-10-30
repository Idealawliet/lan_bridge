/// 根据已知错误关键字给出下一步建议；界面仍需显示原始错误。
/// 这里提供排查方向，并不把字符串匹配结果当作已确认的故障原因。
String connectionAdvice(String error) {
  // 统一英文大小写，让 PIN、Permission、Socket 等写法使用相同规则。
  final value = error.toLowerCase();
  // 版本校验失败时优先指导统一版本，避免用户反复尝试无效连接。
  if (value.contains('版本不一致')) {
    return '请在两台电脑的设置中安装相同版本，然后重新连接。';
  }
  // PIN 相关报错优先检查当前验证码，旧 PIN 可能已经失效。
  if (value.contains('pin')) {
    return '请核对客户端当前显示的 6 位 PIN 码，并重新输入。';
  }
  // 同时识别本地中文提示和原生平台返回的英文权限错误。
  if (value.contains('权限') || value.contains('permission')) {
    return '请检查系统的辅助功能和输入监控权限，然后重新启动应用。';
  }
  // 将超时、拒绝连接和套接字异常归入网络排查，涵盖常见系统错误文本。
  if (value.contains('超时') ||
      value.contains('timeout') ||
      value.contains('refused') ||
      value.contains('socket')) {
    return '请确认两台电脑位于同一局域网、客户端正在运行，并检查防火墙和连接地址。';
  }
  // 未识别错误给出通用步骤，并提示保留原始信息供进一步定位。
  return '请检查两台电脑的连接状态和网络后重试；如仍失败，请记录上方错误信息。';
}
