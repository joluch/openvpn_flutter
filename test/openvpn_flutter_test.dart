import 'package:flutter_test/flutter_test.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:openvpn_flutter/openvpn_flutter_platform_interface.dart';
import 'package:openvpn_flutter/openvpn_flutter_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockOpenvpnFlutterPlatform
    with MockPlatformInterfaceMixin
    implements OpenvpnFlutterPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final OpenvpnFlutterPlatform initialPlatform = OpenvpnFlutterPlatform.instance;

  test('$MethodChannelOpenvpnFlutter is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelOpenvpnFlutter>());
  });

  test('getPlatformVersion', () async {
    OpenvpnFlutter openvpnFlutterPlugin = OpenvpnFlutter();
    MockOpenvpnFlutterPlatform fakePlatform = MockOpenvpnFlutterPlatform();
    OpenvpnFlutterPlatform.instance = fakePlatform;

    expect(await openvpnFlutterPlugin.getPlatformVersion(), '42');
  });
}
