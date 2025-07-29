import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'openvpn_flutter_platform_interface.dart';

/// An implementation of [OpenvpnFlutterPlatform] that uses method channels.
class MethodChannelOpenvpnFlutter extends OpenvpnFlutterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('openvpn_flutter');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
