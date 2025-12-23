import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:vibration/vibration.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// =============================================================
/// SIMPLE IN-MEMORY LOG BUFFER (+ SAVE TO FILE)
/// =============================================================
class LogBuffer {
  static final List<String> _lines = [];

  static void add(String event, String details) {
    final ts = DateTime.now().toIso8601String();
    _lines.add("$ts | $event | $details");
    print("$ts | $event | $details");
  }

  static String get all =>
      _lines.isEmpty ? "No logs yet." : _lines.join("\n");

  static void clear() => _lines.clear();

  static Future<File?> saveToFile() async {
    if (_lines.isEmpty) return null;
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      "${dir.path}/itknows_log_${DateTime.now().millisecondsSinceEpoch}.txt",
    );
    await file.writeAsString(all);
    return file;
  }
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

/// =============================================================
/// APP ROOT (NO LIFECYCLE OBSERVER)
/// =============================================================
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
/// OPTIMISER STATE (IDENTICAL CONTROL SYSTEM, 2 BPM FIXED)
/// =============================================================
class OptimiserState extends ChangeNotifier {
  double hr = 0;
  bool recording = false;

  static const double sensitivity = 2.0;

  final List<double> hrHistory = [];
  void _addHr(double bpm) {
    hrHistory.add(bpm);
    if (hrHistory.length > 60) hrHistory.removeAt(0);
  }

  bool hapticsEnabled = true;
  void setHapticsEnabled(bool v) {
    hapticsEnabled = v;
    notifyListeners();
  }

  Timer? _loopTimer;

  DateTime? _lastTestTime;
  bool _testInProgress = false;
  DateTime? _testStartTime;

  String? _direction;
  double? _hrBeforeTest;

  bool _plateau = false;
  double? _plateauHr;

  String _advice = "Tap ▶ to start workout";

  void toggleRecording() {
    recording = !recording;

    if (recording) {
      _reset();
      _startLoop();
      _advice = "Learning cadence...";
      LogBuffer.add("START", "recording started");
    } else {
      _stopLoop();
      _advice = "Tap ▶ to start workout";
      LogBuffer.add("STOP", "recording stopped");
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
    if (bpm <= 0) return;
    hr = bpm;
    _addHr(bpm);
    notifyListeners();
  }

  Future<void> _signalUp() async {
    if (!hapticsEnabled) return;
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 120);
    }
  }

  Future<void> _signalDown() async {
    if (!hapticsEnabled) return;
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 300);
    }
  }

  void _tick() {
    if (!recording || hr <= 0) return;

    LogBuffer.add(
      "TICK",
      "hr=$hr testInProg=$_testInProgress plateau=$_plateau",
    );

    final now = DateTime.now();
    const interval = 15;
    const delay = 15;

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
        _advice = "Optimal cadence";
        notifyListeners();
        return;
      }
      _plateau = false;
    }

    final dir = _direction ?? "up";
    _startTest(dir);
  }

  void _startTest(String dir) {
    _testInProgress = true;
    _direction = dir;
    _testStartTime = DateTime.now();
    _lastTestTime = _testStartTime;
    _hrBeforeTest = hr;

    LogBuffer.add("TEST_START", "dir=$dir hrBefore=$_hrBeforeTest");

    if (dir == "up") {
      _advice = "Increase cadence";
      _signalUp();
    } else {
      _advice = "Ease cadence";
      _signalDown();
    }

    notifyListeners();
  }

  void _evaluateTest() {
    _testInProgress = false;
    if (_hrBeforeTest == null) return;

    final delta = hr - _hrBeforeTest!;
    LogBuffer.add("EVAL", "delta=$delta thr=$sensitivity");

    if (delta.abs() < sensitivity) {
      _plateau = true;
      _plateauHr = hr;
      _advice = "Optimal cadence";
      LogBuffer.add("PLATEAU", "hr=$hr");
      notifyListeners();
      return;
    }

    if (delta < -sensitivity) {
      _advice = _direction == "up"
          ? "Good response. Slightly higher cadence is efficient."
          : "Good response. Slightly easier cadence is efficient.";
    } else if (delta > sensitivity) {
      final old = _direction;
      _direction = old == "up" ? "down" : "up";
      _advice = old == "up"
          ? "Too costly. Next I'll ease cadence."
          : "Too easy. Next I'll increase cadence.";
    }

    notifyListeners();
  }

  String get rhythmAdvice =>
      recording ? _advice : "Tap ▶ to start workout";

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (_advice == "Optimal cadence") return Colors.green;
    if (_advice == "Learning cadence...") return Colors.grey;
    return Colors.orange;
  }

  @override
  void dispose() {
    _loopTimer?.cancel();
    super.dispose();
  }
}

/// =============================================================
/// BLE MANAGER
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

    _scanSub = _ble.scanForDevices(withServices: []).listen((d) {
      if (!devices.any((x) => x.id == d.id)) {
        devices.add(d);
        notifyListeners();
      }
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
      return data.length >= 3 ? data[1] | (data[2] << 8) : 0;
    } else {
      return data.length >= 2 ? data[1] : 0;
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
    });
  }

  Future<void> disconnect() async {
    await _hrSub?.cancel();
    await _connSub?.cancel();
    connectedId = null;
    connectedName = null;
    notifyListeners();
  }
}

/// =============================================================
/// DASHBOARD UI
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Vibration cues: "),
              Switch(
                value: opt.hapticsEnabled,
                onChanged: opt.setHapticsEnabled,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(height: 200, child: HrGraph(opt: opt)),
          if (ble.connectedName != null)
            Text("Connected to: ${ble.connectedName}",
                style: const TextStyle(color: Colors.black54)),
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
/// LOG VIEWER
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
            icon: const Icon(Icons.save_alt),
            onPressed: () async {
              final file = await LogBuffer.saveToFile();
              if (file != null) {
                await Share.shareXFiles([XFile(file.path)]);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              LogBuffer.clear();
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          text,
          style: const TextStyle(fontFamily: "monospace", fontSize: 12),
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
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: devices.isEmpty
                  ? const Text(
                      "No devices found.\nEnsure HR strap is on.",
                      textAlign: TextAlign.center,
                    )
                  : ListView.builder(
                      itemCount: devices.length,
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
                            if (mounted) Navigator.pop(context);
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
      minY = (minVal - 5).clamp(40, 999);
      maxY = maxVal + 5;
    }

    final maxX =
        points.isEmpty ? 1.0 : (points.length - 1).toDouble();

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
          )
        ],
        titlesData: FlTitlesData(show: false),
        gridData: FlGridData(show: false),
        borderData: FlBorderData(show: false),
      ),
    );
  }
}
