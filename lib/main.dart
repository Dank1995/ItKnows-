import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter/services.dart';

/// =============================================================
/// ENTRY POINT
/// =============================================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final opt = OptimiserState();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => opt),
        ChangeNotifierProvider(create: (_) => BleManager()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Physiological Optimiser',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: const AppBarTheme(centerTitle: true),
      ),
      home: const OptimiserDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// =============================================================
/// FEEDBACK MODE (HAPTIC ONLY)
/// =============================================================
enum FeedbackMode { haptic }

/// =============================================================
/// HR-ONLY OPTIMISER STATE
/// =============================================================
class OptimiserState extends ChangeNotifier {
  // Current HR
  double hr = 0;
  bool recording = false;

  // HR history for graph
  final List<double> hrHistory = [];

  void _addHr(double bpm) {
    hrHistory.add(bpm);
    if (hrHistory.length > 60) hrHistory.removeAt(0);
  }

  // Sensitivity (1–5 bpm)
  double sensitivity = 3.0;
  void setSensitivity(double value) {
    sensitivity = value;
    notifyListeners();
  }

  // Feedback mode
  FeedbackMode feedbackMode = FeedbackMode.haptic;
  void setFeedbackMode(FeedbackMode m) {
    feedbackMode = m;
    notifyListeners();
  }

  /// =============================================================
  /// STRONG + RELIABLE IOS HAPTICS
  /// =============================================================

  /// Increase rhythm → 1 light tap
  Future<void> _signalUp() async {
    HapticFeedback.lightImpact();
  }

  /// Ease rhythm → 2 heavy taps spaced 150ms
  Future<void> _signalDown() async {
    HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 150));
    HapticFeedback.heavyImpact();
  }

  /// =============================================================
  /// GRADIENT ASCENT LOOP
  /// =============================================================
  Timer? _loopTimer;

  DateTime? _lastTestTime;
  bool _testInProgress = false;
  DateTime? _testStartTime;
  String? _direction; // "up" or "down"

  double? _hrBeforeTest;

  bool _plateau = false;
  double? _plateauHr;

  String _advice = "Tap ▶ to start workout";

  /// Toggle workout recording
  void toggleRecording() {
    recording = !recording;

    if (recording) {
      _reset();
      _startLoop();
      _advice = "Learning rhythm...";
    } else {
      _stopLoop();
      _advice = "Tap ▶ to start workout";
    }
    notifyListeners();
  }

  void _reset() {
    _plateau = false;
    _plateauHr = null;
    _lastTestTime = null;
    _testInProgress = false;
    _testStartTime = null;
    _direction = null;
    _hrBeforeTest = null;
  }

  void _startLoop() {
    _loopTimer?.cancel();
    _loopTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _stopLoop() {
    _loopTimer?.cancel();
    _loopTimer = null;
  }

  /// HR input from BLE
  void setHr(double bpm) {
    if (bpm <= 0 || bpm.isNaN) return;
    hr = bpm;
    _addHr(bpm);
    notifyListeners();
  }

  /// =============================================================
  /// GRADIENT TICK
  /// =============================================================
  void _tick() {
    if (!recording || hr <= 0) return;

    final now = DateTime.now();
    const int interval = 15;
    const int delay = 15;

    if (_testInProgress) {
      if (_testStartTime != null &&
          now.difference(_testStartTime!).inSeconds >= delay) {
        _evaluateTest();
      }
      return;
    }

    if (_lastTestTime != null &&
        now.difference(_lastTestTime!).inSeconds < interval) {
      return;
    }

    // Plateau detection
    if (_plateau && _plateauHr != null) {
      if ((hr - _plateauHr!).abs() < sensitivity) {
        _advice = "Optimal rhythm";
        notifyListeners();
        return;
      }
      _plateau = false;
    }

    // Decide direction
    const double eps = 0.2;
    String dir;

    // Alternate at the beginning
    if (_direction == null) {
      dir = "up";
    } else {
      dir = (_direction == "up") ? "down" : "up";
    }

    _startTest(dir);
  }

  void _startTest(String dir) {
    _testInProgress = true;
    _direction = dir;
    _testStartTime = DateTime.now();
    _lastTestTime = _testStartTime;

    _hrBeforeTest = hr;

    if (dir == "up") {
      _advice = "Increase rhythm";
      _signalUp();
    } else {
      _advice = "Ease rhythm";
      _signalDown();
    }

    notifyListeners();
  }

  void _evaluateTest() {
    _testInProgress = false;
    if (_hrBeforeTest == null) return;

    final delta = hr - _hrBeforeTest!;
    final double plate = sensitivity;

    if (delta.abs() < plate) {
      _plateau = true;
      _plateauHr = hr;
      _advice = "Optimal rhythm";
      notifyListeners();
      return;
    }

    notifyListeners();
  }

  /// Public getters
  String get rhythmAdvice => recording ? _advice : "Tap ▶ to start workout";

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (_advice == "Optimal rhythm") return Colors.green;
    if (_advice == "Learning rhythm...") return Colors.grey;
    return Colors.orange;
  }
}

/// =============================================================
/// BLE MANAGER
/// =============================================================
class BleManager extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid hrService = Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement = Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _hrSub;

  String? connectedId;
  String? connectedName;
  bool scanning = false;

  Future<void> ensurePermissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
  }

  Future<List<DiscoveredDevice>> scanDevices({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await ensurePermissions();

    final List<DiscoveredDevice> devices = [];
    scanning = true;
    notifyListeners();

    final completer = Completer<List<DiscoveredDevice>>();

    _scanSub = _ble
        .scanForDevices(withServices: [])
        .listen((d) {
      if (!devices.any((x) => x.id == d.id)) {
        devices.add(d);
        notifyListeners();
      }
    }, onError: (_) {
      if (!completer.isCompleted) completer.complete(devices);
    });

    Future.delayed(timeout, () async {
      await _scanSub?.cancel();
      scanning = false;
      notifyListeners();
      if (!completer.isCompleted) completer.complete(devices);
    });

    return completer.future;
  }

  int _parseHr(List<int> data) {
    if (data.isEmpty) return 0;
    final flags = data[0];
    final is16 = (flags & 0x01) != 0;
    if (is16) {
      if (data.length < 3) return 0;
      return data[1] | (data[2] << 8);
    } else {
      if (data.length < 2) return 0;
      return data[1];
    }
  }

  Future<void> connect(String id, String name, OptimiserState opt) async {
    _connSub?.cancel();
    _hrSub?.cancel();

    _connSub = _ble.connectToDevice(id: id).listen((event) {
      if (event.connectionState == DeviceConnectionState.connected) {
        connectedId = id;
        connectedName = name.isEmpty ? "(unknown)" : name;
        notifyListeners();

        final hrChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: hrService,
          characteristicId: hrMeasurement,
        );

        _hrSub = _ble.subscribeToCharacteristic(hrChar).listen((data) {
          final bpm = _parseHr(data);
          if (bpm > 0) opt.setHr(bpm.toDouble());
        });
      } else if (event.connectionState ==
          DeviceConnectionState.disconnected) {
        connectedId = null;
        connectedName = null;
        notifyListeners();
      }
    }, onError: (_) {
      connectedId = null;
      connectedName = null;
      notifyListeners();
    });
  }

  Future<void> disconnect() async {
    await _hrSub?.cancel();
    await _connSub?.cancel();
    connectedId = null;
    connectedName = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _hrSub?.cancel();
    super.dispose();
  }
}

/// =============================================================
/// MAIN DASHBOARD UI
/// =============================================================
class OptimiserDashboard extends StatelessWidget {
  const OptimiserDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final opt = context.watch<OptimiserState>();
    final ble = context.watch<BleManager>();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            ble.connectedId == null
                ? Icons.bluetooth
                : Icons.bluetooth_connected,
          ),
          tooltip: ble.connectedName == null
              ? 'Bluetooth devices'
              : 'Connected: ${ble.connectedName}',
          onPressed: () => _openBleSheet(context),
        ),
        title: const Text("Physiological Optimiser"),
      ),
      body: Column(
        children: [
          const SizedBox(height: 20),
          Text(
            opt.rhythmAdvice,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: opt.rhythmColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text("HR: ${opt.hr.toStringAsFixed(0)} bpm"),

          /// Sensitivity selector
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Sensitivity: "),
              DropdownButton<double>(
                value: opt.sensitivity,
                items: const [
                  DropdownMenuItem(value: 1.0, child: Text("1 bpm")),
                  DropdownMenuItem(value: 2.0, child: Text("2 bpm")),
                  DropdownMenuItem(value: 3.0, child: Text("3 bpm")),
                  DropdownMenuItem(value: 4.0, child: Text("4 bpm")),
                  DropdownMenuItem(value: 5.0, child: Text("5 bpm")),
                ],
                onChanged: (v) {
                  if (v != null) opt.setSensitivity(v);
                },
              ),
            ],
          ),

          /// Feedback mode
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Feedback: "),
              DropdownButton<FeedbackMode>(
                value: opt.feedbackMode,
                items: const [
                  DropdownMenuItem(
                    value: FeedbackMode.haptic,
                    child: Text("Haptic"),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) opt.setFeedbackMode(v);
                },
              ),
            ],
          ),

          const SizedBox(height: 10),
          SizedBox(height: 200, child: HrGraph(opt: opt)),
          const SizedBox(height: 10),

          if (ble.connectedName != null)
            Text(
              "Connected to: ${ble.connectedName}",
              style: const TextStyle(color: Colors.black54),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: opt.recording ? Colors.red : Colors.green,
        child: Icon(opt.recording ? Icons.stop : Icons.play_arrow),
        onPressed: () => opt.toggleRecording(),
      ),
    );
  }

  void _openBleSheet(BuildContext ctx) {
    final ble = ctx.read<BleManager>();
    showModalBottomSheet(
      context: ctx,
      builder: (_) => ChangeNotifierProvider.value(
        value: ble,
        child: const _BleBottomSheet(),
      ),
    );
  }
}

/// =============================================================
/// BLE DEVICE PICKER UI
/// =============================================================
class _BleBottomSheet extends StatefulWidget {
  const _BleBottomSheet();

  @override
  State<_BleBottomSheet> createState() => _BleBottomSheetState();
}

class _BleBottomSheetState extends State<_BleBottomSheet> {
  List<DiscoveredDevice> devices = [];

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    final ble = context.read<BleManager>();
    devices = await ble.scanDevices();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleManager>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth),
                const SizedBox(width: 8),
                Text(
                  ble.scanning ? "Scanning…" : "Bluetooth Devices",
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (ble.connectedId != null)
                  IconButton(
                    icon: const Icon(Icons.link_off),
                    tooltip: "Disconnect",
                    onPressed: () => ble.disconnect(),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            Flexible(
              child: devices.isEmpty
                  ? const Text(
                      "No devices found.\nEnsure HR strap is on and advertising.",
                      textAlign: TextAlign.center,
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final d = devices[i];
                        final name = d.name.isNotEmpty ? d.name : "(unknown)";
                        return ListTile(
                          leading: const Icon(Icons.watch),
                          title: Text(name),
                          subtitle: Text(d.id),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            final opt = context.read<OptimiserState>();
                            await ble.connect(d.id, name, opt);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                TextButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Rescan"),
                ),
                const Spacer(),
                TextButton(
                  child: const Text("Close"),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// =============================================================
/// HR GRAPH WIDGET
/// =============================================================
class HrGraph extends StatelessWidget {
  final OptimiserState opt;
  const HrGraph({super.key, required this.opt});

  @override
  Widget build(BuildContext context) {
    final points = opt.hrHistory
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value))
        .toList();

    double minY = 50;
    double maxY = 180;

    if (points.isNotEmpty) {
      double minVal = points.first.y;
      double maxVal = points.first.y;

      for (final p in points) {
        if (p.y < minVal) minVal = p.y;
        if (p.y > maxVal) maxVal = p.y;
      }

      minY = minVal - 5;
      maxY = maxVal + 5;

      if (minY < 40) minY = 40;
      if (maxY < minY + 10) maxY = minY + 10;
    }

    final maxX = points.isEmpty ? 1.0 : (points.length - 1).toDouble();

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            barWidth: 3,
            color: Colors.green,
            dotData: FlDotData(show: false),
          ),
        ],
        titlesData: FlTitlesData(show: false),
        gridData: FlGridData(show: false),
        borderData: FlBorderData(show: false),
      ),
    );
  }
}
