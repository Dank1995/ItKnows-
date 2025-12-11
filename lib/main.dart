import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:vibration/vibration.dart';

/// =============================================================
/// SIMPLE IN-MEMORY LOGGER (NO FILES REQUIRED)
/// =============================================================
class LogBuffer {
  static final List<String> _lines = [];

  static void add(String event, String details) {
    final ts = DateTime.now().toIso8601String();
    final line = "$ts | $event | $details";
    _lines.add(line);
    print(line);
  }

  static String get all =>
      _lines.isEmpty ? "No logs yet." : _lines.join("\n");

  static void clear() => _lines.clear();
}

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
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const OptimiserDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// =============================================================
/// FEEDBACK MODE
/// =============================================================
enum FeedbackMode { haptic }

/// =============================================================
/// OPTIMISER STATE (LOGIC UNCHANGED — ONLY LOGGING ADDED)
/// =============================================================
class OptimiserState extends ChangeNotifier {
  double hr = 0;
  bool recording = false;

  final List<double> hrHistory = [];

  void _addHr(double bpm) {
    hrHistory.add(bpm);
    if (hrHistory.length > 60) hrHistory.removeAt(0);
  }

  double sensitivity = 3.0;
  void setSensitivity(double value) {
    sensitivity = value;
    notifyListeners();
  }

  FeedbackMode feedbackMode = FeedbackMode.haptic;
  void setFeedbackMode(FeedbackMode m) {
    feedbackMode = m;
    notifyListeners();
  }

  // ------------------------
  // LOGGER WRAPPER
  // ------------------------
  void _log(String event, String details) =>
      LogBuffer.add(event, details);

  // ------------------------
  // HAPTICS
  // ------------------------
  Future<bool> _canVibrate() async =>
      (feedbackMode == FeedbackMode.haptic) &&
          (await Vibration.hasVibrator() ?? false);

  Future<void> _signalUp() async {
    if (await _canVibrate()) Vibration.vibrate(duration: 120);
  }

  Future<void> _signalDown() async {
    if (await _canVibrate()) Vibration.vibrate(duration: 300);
  }

  // ------------------------
  // OPTIMISER LOOP VARIABLES
  // ------------------------
  Timer? _loopTimer;
  DateTime? _lastTestTime;
  bool _testInProgress = false;
  DateTime? _testStartTime;
  String? _direction;
  double? _hrBeforeTest;

  bool _plateau = false;
  double? _plateauHr;

  String _advice = "Tap ▶ to start workout";

  // ------------------------
  // RECORDING TOGGLE
  // ------------------------
  void toggleRecording() {
    recording = !recording;

    if (recording) {
      _reset();
      _startLoop();
      _advice = "Learning rhythm...";
      _log("START", "Session started");
    } else {
      _stopLoop();
      _advice = "Tap ▶ to start workout";
      _log("STOP", "Session stopped");
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
    _loopTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _stopLoop() {
    _loopTimer?.cancel();
    _loopTimer = null;
  }

  void setHr(double bpm) {
    if (bpm <= 0 || bpm.isNaN) return;
    hr = bpm;
    _addHr(bpm);
    notifyListeners();
  }

  // ------------------------
  // MAIN LOOP
  // ------------------------
  void _tick() {
    if (!recording || hr <= 0) return;

    _log("TICK",
        "hr=$hr testInProg=$_testInProgress plateau=$_plateau");

    final now = DateTime.now();
    const int interval = 15;
    const int delay = 15;

    if (_testInProgress) {
      if (now.difference(_testStartTime!).inSeconds >= delay) {
        _evaluateTest();
      }
      return;
    }

    if (_lastTestTime != null &&
        now.difference(_lastTestTime!).inSeconds < interval) {
      return;
    }

    if (_plateau && _plateauHr != null) {
      if ((hr - _plateauHr!).abs() < sensitivity) {
        _advice = "Optimal rhythm";
        notifyListeners();
        return;
      }
      _plateau = false;
    }

    final dir = _direction ?? "up";
    _startTest(dir);
  }

  // ------------------------
  // START TEST
  // ------------------------
  void _startTest(String dir) {
    _testInProgress = true;
    _direction = dir;
    _testStartTime = DateTime.now();
    _lastTestTime = _testStartTime;
    _hrBeforeTest = hr;

    _log("TEST_START", "dir=$dir hrBefore=$_hrBeforeTest");

    if (dir == "up") {
      _advice = "Increase rhythm";
      _signalUp();
    } else {
      _advice = "Ease rhythm";
      _signalDown();
    }

    notifyListeners();
  }

  // ------------------------
  // EVALUATE TEST (LOGIC UNCHANGED)
  // ------------------------
  void _evaluateTest() {
    _testInProgress = false;
    if (_hrBeforeTest == null) return;

    final delta = hr - _hrBeforeTest!;
    final plate = sensitivity;

    _log("EVAL",
        "dir=$_direction hrBefore=$_hrBeforeTest hrNow=$hr delta=$delta");

    // Plateau
    if (delta.abs() < plate) {
      _plateau = true;
      _plateauHr = hr;
      _advice = "Optimal rhythm";
      _log("PLATEAU", "hr=$hr thr=$plate");
      notifyListeners();
      return;
    }

    // HR went down → good direction
    if (delta < -plate) {
      _log("GOOD", "dir=$_direction delta=$delta");

      _advice = _direction == "up"
          ? "Good response. Slightly higher rhythm is efficient."
          : "Good response. Slightly easier rhythm is efficient.";
    }

    // HR went up → bad direction
    else if (delta > plate) {
      final old = _direction;
      _direction = old == "up" ? "down" : "up";

      _log("BAD_FLIP", "old=$old new=$_direction delta=$delta");

      _advice = old == "up"
          ? "Too costly. Next I'll ease rhythm."
          : "Too easy. Next I'll increase rhythm.";
    }

    notifyListeners();
  }

  String get rhythmAdvice =>
      recording ? _advice : "Tap ▶ to start workout";

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (_advice == "Optimal rhythm") return Colors.green;
    if (_advice == "Learning rhythm...") return Colors.grey;
    return Colors.orange;
  }

  @override
  void dispose() {
    _loopTimer?.cancel();
    super.dispose();
  }
}

/// =============================================================
/// BLE MANAGER (UNCHANGED)
/// =============================================================
class BleManager extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final Uuid hrService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

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

    final devices = <DiscoveredDevice>[];
    scanning = true;
    notifyListeners();

    final completer = Completer<List<DiscoveredDevice>>();

    _scanSub = _ble.scanForDevices(withServices: []).listen(
      (d) {
        if (!devices.any((x) => x.id == d.id)) {
          devices.add(d);
          notifyListeners();
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(devices);
      },
    );

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
    return is16 && data.length >= 3
        ? data[1] | (data[2] << 8)
        : data.length >= 2
            ? data[1]
            : 0;
  }

  Future<void> connect(
      String id, String name, OptimiserState opt) async {
    _connSub?.cancel();
    _hrSub?.cancel();

    _connSub = _ble.connectToDevice(id: id).listen(
      (event) {
        if (event.connectionState ==
            DeviceConnectionState.connected) {
          connectedId = id;
          connectedName = name.isEmpty ? "(unknown)" : name;
          notifyListeners();

          final hrChar = QualifiedCharacteristic(
            deviceId: id,
            serviceId: hrService,
            characteristicId: hrMeasurement,
          );

          _hrSub = _ble.subscribeToCharacteristic(hrChar).listen(
            (data) {
              final bpm = _parseHr(data);
              if (bpm > 0) opt.setHr(bpm.toDouble());
            },
          );
        } else if (event.connectionState ==
            DeviceConnectionState.disconnected) {
          connectedId = null;
          connectedName = null;
          notifyListeners();
        }
      },
    );
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
/// MAIN DASHBOARD
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
          onPressed: () => _openBleSheet(context),
        ),
        title: const Text("Physiological Optimiser"),

        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: "View Logs",
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LogViewerPage()),
            ),
          ),
        ],
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
          const SizedBox(height: 10),
          SizedBox(height: 200, child: HrGraph(opt: opt)),
        ],
      ),

      floatingActionButton: FloatingActionButton(
        backgroundColor: opt.recording ? Colors.red : Colors.green,
        child:
            Icon(opt.recording ? Icons.stop : Icons.play_arrow),
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
/// SIMPLE RAW LOG VIEWER
/// =============================================================
class LogViewerPage extends StatelessWidget {
  const LogViewerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = LogBuffer.all;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Session Logs"),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: "Clear logs",
            onPressed: () {
              LogBuffer.clear();
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style:
              const TextStyle(fontFamily: "monospace", fontSize: 11),
        ),
      ),
    );
  }
}

/// =============================================================
/// BLE DEVICE PICKER
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
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ble.scanning ? "Scanning…" : "Bluetooth Devices",
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: devices.isEmpty
                  ? const Center(
                      child: Text(
                        "No devices found.\nEnsure HR strap is on.",
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final d = devices[i];
                        final name =
                            d.name.isNotEmpty ? d.name : "(unknown)";
                        return ListTile(
                          leading: const Icon(Icons.watch),
                          title: Text(name),
                          subtitle: Text(d.id),
                          onTap: () async {
                            final opt =
                                context.read<OptimiserState>();
                            await ble.connect(d.id, name, opt);
                            if (context.mounted) Navigator.pop(context);
                          },
                        );
                      },
                    ),
            ),

            TextButton(
              onPressed: _startScan,
              child: const Text("Rescan"),
            ),
          ],
        ),
      ),
    );
  }
}

/// =============================================================
/// HR GRAPH
/// =============================================================
class HrGraph extends StatelessWidget {
  final OptimiserState opt;
  const HrGraph({super.key, required this.opt});

  @override
  Widget build(BuildContext context) {
    final points = opt.hrHistory
        .asMap()
        .entries
        .map((e) =>
            FlSpot(e.key.toDouble(), e.value))
        .toList();

    final maxX =
        points.isEmpty ? 1.0 : (points.length - 1).toDouble();

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: 40,
        maxY: 200,
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
        borderData: FlBorderData(show: false),
        gridData: FlGridData(show: false),
      ),
    );
  }
}
