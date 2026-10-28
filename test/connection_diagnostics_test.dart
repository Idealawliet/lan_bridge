import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/connection_diagnostics.dart';

void main() {
  test('gives actionable guidance for known failures and a safe fallback', () {
    expect(connectionAdvice('软件版本不一致'), contains('相同版本'));
    expect(connectionAdvice('PIN 码不正确'), contains('6 位'));
    expect(
      connectionAdvice('SocketException: Connection refused'),
      contains('防火墙'),
    );
    expect(connectionAdvice('permission denied'), contains('权限'));
    expect(connectionAdvice('未知异常'), contains('错误信息'));
  });
}
