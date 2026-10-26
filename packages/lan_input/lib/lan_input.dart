import 'dart:io';
import 'package:flutter/services.dart';

class InputStatus {
  const InputStatus(
      {required this.supported,
      required this.accessibility,
      required this.inputMonitoring,
      required this.screen});
  final bool supported;
  final bool accessibility;
  final bool inputMonitoring;
  final Map<String, double> screen;
  bool get permissionsGranted => accessibility && inputMonitoring;
  factory InputStatus.fromMap(Map<dynamic, dynamic> map) {
    final raw = Map<dynamic, dynamic>.from(map['screen'] as Map? ?? {});
    return InputStatus(
      supported: map['supported'] == true,
      accessibility: map['accessibility'] == true,
      inputMonitoring: map['inputMonitoring'] == true,
      screen: {
        for (final key in ['x', 'y', 'width', 'height'])
          key: (raw[key] as num?)?.toDouble() ?? 0
      },
    );
  }
}

class LanInput {
  static const _methods = MethodChannel('lan_input/methods');
  static const _events = EventChannel('lan_input/events');
  Stream<Map<String, dynamic>>? _stream;
  Stream<Map<String, dynamic>> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));

  Future<InputStatus> getStatus() async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return const InputStatus(
          supported: false,
          accessibility: false,
          inputMonitoring: false,
          screen: {'x': 0, 'y': 0, 'width': 0, 'height': 0});
    }
    return InputStatus.fromMap(
        await _methods.invokeMapMethod<String, dynamic>('getStatus') ?? {});
  }

  Future<void> requestPermissions() =>
      _methods.invokeMethod('requestPermissions');
  Future<void> startCapture() => _methods.invokeMethod('startCapture');
  Future<void> stopCapture() => _methods.invokeMethod('stopCapture');
  Future<void> setRemoteCapture(bool enabled) =>
      _methods.invokeMethod('setRemoteCapture', {'enabled': enabled});
  Future<void> setCursorVisible(bool visible) =>
      _methods.invokeMethod('setCursorVisible', {'visible': visible});
  Future<void> heartbeat() => _methods.invokeMethod('heartbeat');
  Future<void> inject(Map<String, dynamic> event) =>
      _methods.invokeMethod('inject', {'event': event});
  Future<void> warp(double x, double y) =>
      _methods.invokeMethod('warp', {'x': x, 'y': y});
  Future<void> releaseAll() => _methods.invokeMethod('releaseAll');
  Future<int> clipboardRevision() async =>
      await _methods.invokeMethod<int>('clipboardRevision') ?? 0;
  Future<bool> clipboardHasFiles() async =>
      await _methods.invokeMethod<bool>('clipboardHasFiles') ?? false;
  Future<void> configureFileEdge(bool enabled, bool left) => _methods
      .invokeMethod('configureFileEdge', {'enabled': enabled, 'left': left});
  Future<void> configureFileEdgeLayout(
          bool enabled, String edge, double start, double end) =>
      _methods.invokeMethod('configureFileEdge',
          {'enabled': enabled, 'edge': edge, 'start': start, 'end': end});
  Future<void> prepareFileDrag() => _methods.invokeMethod('prepareFileDrag');
  Future<void> cancelLocalDrag() => _methods.invokeMethod('cancelLocalDrag');
  Future<void> beginFileDrag(List<String> paths) =>
      _methods.invokeMethod('beginFileDrag', {'paths': paths});
  Future<void> cancelFileDrag() => _methods.invokeMethod('cancelFileDrag');
}
