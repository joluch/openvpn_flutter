import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'openvpn_flutter_method_channel.dart';

abstract class OpenvpnFlutterPlatform extends PlatformInterface {
  /// Constructs a OpenvpnFlutterPlatform.
  OpenvpnFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static OpenvpnFlutterPlatform _instance = MethodChannelOpenvpnFlutter();

  /// The default instance of [OpenvpnFlutterPlatform] to use.
  ///
  /// Defaults to [MethodChannelOpenvpnFlutter].
  static OpenvpnFlutterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [OpenvpnFlutterPlatform] when
  /// they register themselves.
  static set instance(OpenvpnFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
