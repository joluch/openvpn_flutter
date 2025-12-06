import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:nativewrappers/_internal/vm/lib/ffi_allocation_patch.dart';
import 'package:flutter/services.dart';
import 'model/vpn_status.dart';

///Stages of vpn connections
enum VPNStage {
  prepare,
  authenticating,
  connecting,
  authentication,
  connected,
  disconnected,
  disconnecting,
  denied,
  error,
  // ignore: constant_identifier_names
  wait_connection,
  // ignore: constant_identifier_names
  vpn_generate_config,
  // ignore: constant_identifier_names
  get_config,
  // ignore: constant_identifier_names
  tcp_connect,
  // ignore: constant_identifier_names
  udp_connect,
  // ignore: constant_identifier_names
  assign_ip,
  resolve,
  exiting,
  unknown,
}

class OpenVPN {
  ///Channel's names of _vpnStageSnapshot
  static const String _eventChannelVpnStage =
      "id.laskarmedia.openvpn_flutter/vpnstage";

  ///Channel's names of _channelControl
  static const String _methodChannelVpnControl =
      "id.laskarmedia.openvpn_flutter/vpncontrol";

  ///Method channel to invoke methods from native side
  static const MethodChannel _channelControl = MethodChannel(
    _methodChannelVpnControl,
  );

  ///Snapshot of stream that produced by native side
  static Stream<String> _vpnStageSnapshot() =>
      const EventChannel(_eventChannelVpnStage).receiveBroadcastStream().cast();

  ///Timer to get vpnstatus as a loop
  ///
  ///I know it was bad practice, but this is the only way to avoid android status duration having long delay
  Timer? _vpnStatusTimer;

  ///To indicate the engine already initialize
  bool initialized = false;

  ///Use tempDateTime to countdown, especially on android that has delays
  DateTime? _tempDateTime;

  VPNStage? _lastStage;

  /// is a listener to see vpn status detail
  final Function(VpnStatus? data)? onVpnStatusChanged;

  /// is a listener to see what stage the connection was
  final Function(VPNStage stage, String rawStage)? onVpnStageChanged;

  /// OpenVPN's Constructions, don't forget to implement the listeners
  /// onVpnStatusChanged is a listener to see vpn status detail
  /// onVpnStageChanged is a listener to see what stage the connection was
  OpenVPN({this.onVpnStatusChanged, this.onVpnStageChanged});

  ///This function should be called before any usage of OpenVPN
  ///All params required for iOS, make sure you read the plugin's documentation
  ///
  ///
  ///providerBundleIdentfier is for your Network Extension identifier
  ///
  ///localizedDescription is for description to show in user's settings
  ///
  ///
  ///Will return latest VPNStage
  Future<void> initialize({
    String? providerBundleIdentifier,
    String? localizedDescription,
    String? groupIdentifier,
    Function(VpnStatus status)? lastStatus,
    Function(VPNStage stage)? lastStage,
    String? windowsOpenVPNPath,
  }) async {
    if (Platform.isIOS) {
      assert(
        groupIdentifier != null &&
            providerBundleIdentifier != null &&
            localizedDescription != null,
        "These values are required for ios.",
      );
    }
    onVpnStatusChanged?.call(VpnStatus.empty());
    initialized = true;

    if (Platform.isWindows) {
      if (windowsOpenVPNPath == null) {
        throw Exception("OpenVPN path needs to be set when using Windows");
      }

      _initializeWindows(windowsOpenVPNPath);

      lastStatus?.call(VpnStatus.empty());
      lastStage?.call(VPNStage.disconnected);
    } else {
      _initializeListener();
      return _channelControl
          .invokeMethod("initialize", {
            "groupIdentifier": groupIdentifier,
            "providerBundleIdentifier": providerBundleIdentifier,
            "localizedDescription": localizedDescription,
          })
          .then((value) {
            Future.wait([
              status().then((value) => lastStatus?.call(value)),
              stage().then((value) {
                if (value == VPNStage.connected && _vpnStatusTimer == null) {
                  _createTimer();
                }
                return lastStage?.call(value);
              }),
            ]);
          });
    }
  }

  ///Connect to VPN
  ///
  ///config : Your openvpn configuration script, you can find it inside your .ovpn file
  ///
  ///name : name that will show in user's notification
  ///
  ///certIsRequired : default is false, if your config file has cert, set it to true
  ///
  ///username & password : set your username and password if your config file has auth-user-pass
  ///
  ///bypassPackages : exclude some apps to access/use the VPN Connection, it was List<String> of applications package's name (Android Only)
  Future connect(
    String config,
    String name, {
    String? username,
    String? password,
    List<String>? bypassPackages,
    bool certIsRequired = false,
  }) {
    if (!initialized) {
      throw ("OpenVPN need to be initialized");
    }

    if (Platform.isWindows) {
      return _windowsImplementation!.connectWindows(
        config,
        name,
        username: username,
        password: password,
        certIsRequired: certIsRequired,
      );
    }

    if (!certIsRequired) {
      config += "client-cert-not-required";
    }
    _tempDateTime = DateTime.now();

    try {
      return _channelControl.invokeMethod("connect", {
        "config": config,
        "name": name,
        "username": username,
        "password": password,
        "bypass_packages": bypassPackages ?? [],
      });
    } on PlatformException catch (e) {
      throw ArgumentError(e.message);
    }
  }

  ///Disconnect from VPN
  void disconnect() {
    _tempDateTime = null;

    if (Platform.isWindows) {
      _disconnectWindows();
      return;
    }

    _channelControl.invokeMethod("disconnect");
    if (_vpnStatusTimer?.isActive ?? false) {
      _vpnStatusTimer?.cancel();
      _vpnStatusTimer = null;
    }
  }

  ///Check if connected to vpn
  Future<bool> isConnected() async =>
      stage().then((value) => value == VPNStage.connected);

  ///Get latest connection stage
  Future<VPNStage> stage() async {
    String? stage = await _channelControl.invokeMethod("stage");
    return _strToStage(stage ?? "disconnected");
  }

  ///
  /// Get the VPN logs
  ///
  Future<String?> log() async {
    if (Platform.isWindows) {
      // TODO: Implement windows logging properly.
      return "Windows logging not yet implemented";
    }

    String? log = await _channelControl.invokeMethod("log");

    return log;
  }

  ///
  /// Write to the VPN log
  ///
  Future<void> addToLog(String logMessage) async {
    if (Platform.isWindows) {
      _windowsLogController.add(logMessage);
      return;
    }

    await _channelControl.invokeMethod("add_to_log", {"message": logMessage});
  }

  ///Get latest connection status
  Future<VpnStatus> status() {
    //Have to check if user already connected to get real data
    return stage().then((value) async {
      var status = VpnStatus.empty();
      if (value == VPNStage.connected) {
        if (Platform.isWindows) {
          final connectedOn = _tempDateTime ?? DateTime.now();
          return VpnStatus(
            connectedOn: connectedOn,
            duration: _duration(DateTime.now().difference(connectedOn).abs()),
            // TODO: Implement on Windows
            byteIn: "0",
            byteOut: "0",
            packetsIn: "0",
            packetsOut: "0",
          );
        }

        status = await _channelControl.invokeMethod("status").then((value) {
          if (value == null) {
            return VpnStatus.empty();
          }

          if (Platform.isIOS) {
            var splitted = value.split("_");
            var connectedOn = DateTime.tryParse(splitted[0]);
            if (connectedOn == null) return VpnStatus.empty();
            return VpnStatus(
              connectedOn: connectedOn,
              duration: _duration(DateTime.now().difference(connectedOn).abs()),
              packetsIn: splitted[1],
              packetsOut: splitted[2],
              byteIn: splitted[3],
              byteOut: splitted[4],
            );
          } else if (Platform.isAndroid) {
            var data = jsonDecode(value);
            var connectedOn =
                DateTime.tryParse(data["connected_on"].toString()) ??
                _tempDateTime ??
                DateTime.now();
            String byteIn =
                data["byte_in"] != null ? data["byte_in"].toString() : "0";
            String byteOut =
                data["byte_out"] != null ? data["byte_out"].toString() : "0";
            if (byteIn.trim().isEmpty) byteIn = "0";
            if (byteOut.trim().isEmpty) byteOut = "0";
            return VpnStatus(
              connectedOn: connectedOn,
              duration: _duration(DateTime.now().difference(connectedOn).abs()),
              byteIn: byteIn,
              byteOut: byteOut,
              packetsIn: byteIn,
              packetsOut: byteOut,
            );
          } else {
            throw Exception("Openvpn not supported on this platform");
          }
        });
      }
      return status;
    });
  }

  ///Request android permission (Return true if already granted)
  Future<bool> requestPermissionAndroid() async {
    return _channelControl
        .invokeMethod("request_permission")
        .then((value) => value ?? false);
  }

  ///Sometimes config script has too many Remotes, it cause ANR in several devices,
  ///This happened because the plugin check every remote and somehow affected the UI to freeze
  ///
  ///Use this function if you wanted to force user to use 1 remote by randomize the remotes provided
  static Future<String?> filteredConfig(String? config) async {
    List<String> remotes = [];
    List<String> output = [];
    if (config == null) return null;
    var raw = config.split("\n");

    for (var item in raw) {
      if (item.trim().toLowerCase().startsWith("remote ")) {
        if (!output.contains("REMOTE_HERE")) {
          output.add("REMOTE_HERE");
        }
        remotes.add(item);
      } else {
        output.add(item);
      }
    }
    String fastestServer = remotes[Random().nextInt(remotes.length - 1)];
    int indexRemote = output.indexWhere((element) => element == "REMOTE_HERE");
    output.removeWhere((element) => element == "REMOTE_HERE");
    output.insert(indexRemote, fastestServer);
    return output.join("\n");
  }

  ///Convert duration that produced by native side as Connection Time
  String _duration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  ///Private function to convert String to VPNStage
  static VPNStage _strToStage(String? stage) {
    if (stage == null ||
        stage.trim().isEmpty ||
        stage.trim() == "idle" ||
        stage.trim() == "invalid") {
      return VPNStage.disconnected;
    }
    var indexStage = VPNStage.values.indexWhere(
      (element) => element.toString().trim().toLowerCase().contains(
        stage.toString().trim().toLowerCase(),
      ),
    );
    if (indexStage >= 0) return VPNStage.values[indexStage];
    return VPNStage.unknown;
  }

  ///Initialize listener, called when you start connection and stoped while
  void _initializeListener() {
    _vpnStageSnapshot().listen((event) {
      var vpnStage = _strToStage(event);
      if (vpnStage != _lastStage) {
        onVpnStageChanged?.call(vpnStage, event);
        _lastStage = vpnStage;
      }
      if (vpnStage != VPNStage.disconnected) {
        if (Platform.isAndroid) {
          _createTimer();
        } else if (Platform.isIOS && vpnStage == VPNStage.connected) {
          _createTimer();
        }
      } else {
        _vpnStatusTimer?.cancel();
      }
    });
  }

  ///Create timer to invoke status
  void _createTimer() {
    if (_vpnStatusTimer != null) {
      _vpnStatusTimer!.cancel();
      _vpnStatusTimer = null;
    }
    _vpnStatusTimer ??= Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      onVpnStatusChanged?.call(await status());
    });
  }

  final _windowsLogController = StreamController<String>.broadcast();

  String? _openVPNPath;
  Process? _openVPNProcess;
  Socket? _managementSocket;

  Future<void> _initializeWindows(String openVPNPath) async {
    _openVPNPath = openVPNPath;

    if (!Platform.isWindows) {
      throw Exception(
        "Wrong intialization function. Only Windows support for this initialization function.",
      );
    }

    if (_openVPNPath == null) {
      throw Exception(
        "OpenVPN executable not found. Please install OpenVPN or specify the path.",
      );
    }

    final file = File(_openVPNPath!);
    if (!await file.exists()) {
      throw Exception("OpenVPN executable not found at: $_openVPNPath");
    }
  }

  Future<void> connectWindows(
    String config,
    String name, {
    String? username,
    String? password,
    bool certIsRequired = false,
  }) async {
    if (_openVPNProcess != null) {
      return;
    }

    try {
      final tempPath = Directory.systemTemp;
      final configFile = File(
        "${tempPath.path}\\${_randomString()}_${DateTime.now().millisecondsSinceEpoch}.ovpn",
      );

      var modifiedConfig = config;
      if (!certIsRequired && !config.contains("client-cert-not-required")) {
        modifiedConfig += "\nclient-cert-not-required";
      }

      final port = _randomInt(10500, 60000);

      await configFile.writeAsString(modifiedConfig);
      final args = [
        "--config", configFile.path,
        "--management", "127.0.0.1", "$port", // Port
        "--management-query-passwords",
        "--management-hold",
        "--verb", "3",
      ];

      _openVPNProcess = await Process.start(
        _openVPNPath!,
        args,
        runInShell: true,
      );
      _openVPNProcess!.stdout.transform(utf8.decoder).listen((data) {
        _windowsLogController.add(data);
        _parseOpenVPNOutput(data);
      });
      _openVPNProcess!.stderr.transform(utf8.decoder).listen((data) {
        _windowsLogController.add("stderr: $data");
      });
      _openVPNProcess!.exitCode.then((exitCode) {
        _windowsLogController.add("OpenVPN exited with status code: $exitCode");
        if (_lastStage != VPNStage.disconnecting) {
          _updateWindowsStage(VPNStage.error);
        }

        _cleanupWindows();
        configFile.deleteSync();
      });

      // Wait for the management interface to be available
      await Future.delayed(const Duration(seconds: 1));

      try {
        _managementSocket = await Socket.connect("127.0.0.1", port);
        _managementSocket!.listen((data) {
          final response = utf8.decode(data);
          _windowsLogController.add("OpenVPN Management: $response");
        });

        await Future.delayed(const Duration(milliseconds: 500));

        _managementSocket!.write("hold release\r\n");
        await _managementSocket!.flush();

        if (username != null && password != null) {
          await Future.delayed(const Duration(milliseconds: 500));
          _managementSocket!.write('username "Auth" "$username"\r\n');
          await _managementSocket!.flush();

          await Future.delayed(const Duration(milliseconds: 200));
          _managementSocket!.write('password "Auth" "$password"\r\n');
          await _managementSocket!.flush();
        }

        _updateWindowsStage(VPNStage.wait_connection);
      } catch (e) {
        _windowsLogController.add("Management interface error: $e");
      }
    } catch (e) {
      _updateWindowsStage(VPNStage.error);
      _cleanupWindows();
      rethrow;
    }
  }

  void _cleanupWindows() {
    try {
      _managementSocket?.close();
    } catch (_) {
      // Pass
    }

    _managementSocket = null;
    _openVPNProcess = null;

    if (_vpnStatusTimer?.isActive ?? false) {
      _vpnStatusTimer?.cancel();
      _vpnStatusTimer = null;
    }
  }

  void _parseOpenVPNOutput(String output) {
    final lines = output.split("\n");

    for (final line in lines) {
      final lower = line.toLowerCase();

      if (lower.contains('initialization sequence completed')) {
        _updateWindowsStage(VPNStage.connected);
        _createTimer();
      } else if (lower.contains('connecting to')) {
        _updateWindowsStage(VPNStage.tcp_connect);
      } else if (lower.contains('attempting to establish')) {
        _updateWindowsStage(VPNStage.connecting);
      } else if (lower.contains('auth') && lower.contains('succeed')) {
        _updateWindowsStage(VPNStage.authentication);
      } else if (lower.contains('auth') &&
          (lower.contains('failed') || lower.contains('denied'))) {
        _updateWindowsStage(VPNStage.denied);
      } else if (lower.contains('connection reset') ||
          lower.contains('connection refused')) {
        _updateWindowsStage(VPNStage.error);
      } else if (lower.contains('tls error')) {
        _updateWindowsStage(VPNStage.error);
      } else if (lower.contains('resolving')) {
        _updateWindowsStage(VPNStage.resolve);
      } else if (lower.contains('peer connection initiated')) {
        _updateWindowsStage(VPNStage.authenticating);
      } else if (lower.contains('ifconfig') || lower.contains('ipv4')) {
        _updateWindowsStage(VPNStage.assign_ip);
      }
    }
  }

  void _updateWindowsStage(VPNStage stage) {
    if (stage != _lastStage) {
      _lastStage = stage;
      onVpnStageChanged?.call(stage, stage.toString());
    }
  }

  void _disconnectWindows() {
    if (_openVPNProcess == null) {
      return;
    }

    _updateWindowsStage(VPNStage.disconnecting);

    try {
      if (_managementSocket != null) {
        try {
          _managementSocket!.write("signal SIGTERM\r\n");
          _managementSocket!.flush();
        } catch (e) {
          _windowsLogController.add("Error sending disconnect signal: $e");
        }
      }

      Future.delayed(const Duration(seconds: 2)).then((_) {
        _openVPNProcess?.kill(ProcessSignal.sigkill);
      });
    } catch (e) {
      _windowsLogController.add("Error during disconnecting: $e");
    }

    _cleanupWindows();
    _updateWindowsStage(VPNStage.disconnected);
  }

  int _randomInt(int start, int end) {
    final rng = Random();
    return rng.nextInt(end - start) + start;
  }

  String _randomString({int length = 32}) {
    const chars =
        'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
    final rng = Random();

    return String.fromCharCodes(
      Iterable.generate(
        length,
        (_) => chars.codeUnitAt(rng.nextInt(chars.length)),
      ),
    );
  }
}
