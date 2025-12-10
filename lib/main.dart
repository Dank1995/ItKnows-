// ---------------------------------------------------------------
// Physiological Optimiser — with Notification Cues Only
// ---------------------------------------------------------------
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// =============================================================
// NOTIFICATION SERVICE
// =============================================================
class Noti {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosInit = DarwinInitializationSettings();

    const InitializationSettings settings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    await _plugin.initialize(settings);
  }

  static Future<void> up() async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'optimiser_channel',
        'Optimiser Feedback',
        channelDescription: 'Cadence optimisation cues',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.show(
      1,
      'Increase Rhythm',
      'Step slightly quicker',
      details,
    );
  }

  static Future<void> down() async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'optimiser_channel',
        'Optimiser Feedback',
        channelDescription: 'Cadence optimisation cues',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.show(
      2,
      'Ease Rhythm',
      'Slow cadence slightly',
      details,
    );
  }
}

// =============================================================
// ENTRY
// =============================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Noti.init(); // << REQUIRED for notifications

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
      home: const OptimiserDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// =============================================================
// FEEDBACK MODE
// =============================================================
enum FeedbackMode { haptic, notification }

// =============================================================
// OPTIMISER STATE (HR ONLY)
// =============================================================
class OptimiserState extends ChangeNotifier {
  double hr = 0;
  bool recording = false;
  final List<double> hrHistory = [];

  void _addHr(double bpm) {
    hrHistory.add(bpm);
    if (hrHistory.length > 60) hrHistory.removeAt(0);
  }

  double sensitivity = 3.0;
  void setSensitivity(double v) {
    sensitivity = v;
    notifyListeners();
  }

  FeedbackMode feedbackMode = FeedbackMode.notification;

  void setFeedbackMode(FeedbackMode m) {
    feedbackMode = m;
    notifyListeners();
  }

  // Feedback dispatch
  void _cueUp() {
    Noti.up();
  }

  void _cueDown() {
    Noti.down();
  }

  // -----------------------------------------------------------
  // GRADIENT LOGIC
  // -----------------------------------------------------------
  Timer? _loop;
  DateTime? _lastTest;
  DateTime? _start;
  bool _testing = false;
  String? _dir;
  double? _hr0;

  bool _plateau = false;
  double? _plateauHr;

  String _advice = "Tap ▶ to start workout";

  void toggleRecording() {
    recording = !recording;

    if (recording) {
      _reset();
      _startLoop();
      _advice = "Learning rhythm...";
    } else {
      _loop?.cancel();
      _advice = "Tap ▶ to start workout";
    }

    notifyListeners();
  }

  void _reset() {
    _plateau = false;
    _plateauHr = null;
    _testing = false;
    _start = null;
    _lastTest = null;
    _dir = null;
    _hr0 = null;
  }

  void _startLoop() {
    _loop?.cancel();
    _loop = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void setHr(double bpm) {
    if (bpm <= 0 || bpm.isNaN) return;
    hr = bpm;
    _addHr(bpm);
    notifyListeners();
  }

  void _tick() {
    if (!recording || hr <= 0) return;

    final now = DateTime.now();
    const int interval = 15;
    const int delay = 15;

    if (_testing) {
      if (_start != null && now.difference(_start!).inSeconds >= delay) {
        _evaluate();
      }
      return;
    }

    if (_lastTest != null &&
        now.difference(_lastTest!).inSeconds < interval) {
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

    String next;
    next = (_dir == "up") ? "down" : "up";

    _begin(next);
  }

  void _begin(String d) {
    _testing = true;
    _dir = d;
    _start = DateTime.now();
    _lastTest = _start;
    _hr0 = hr;

    if (d == "up") {
      _advice = "Increase rhythm";
      _cueUp();
    } else {
      _advice = "Ease rhythm";
      _cueDown();
    }

    notifyListeners();
  }

  void _evaluate() {
    _testing = false;
    if (_hr0 == null) return;

    final delta = hr - _hr0!;
    final double threshold = sensitivity;

    if (delta.abs() < threshold) {
      _plateau = true;
      _plateauHr = hr;
      _advice = "Optimal rhythm";
      notifyListeners();
      return;
    }

    notifyListeners();
  }

  String get rhythmAdvice => recording ? _advice : "Tap ▶ to start workout";

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (_advice == "Optimal rhythm") return Colors.green;
    if (_advice == "Learning rhythm...") return Colors.grey;
    return Colors.orange;
  }
}

// =============================================================
// BLE MANAGER (unchanged)
// =============================================================
class BleManager extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid hrService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  StreamSubscription<DiscoveredDevice>? _scan;
  StreamSubscription<ConnectionStateUpdate>? _conn;
  StreamSubscription<List<int>>? _hr;

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

    final comp = Completer<List<DiscoveredDevice>>();

    _scan = _ble
        .scanForDevices(withServices: [])
        .listen((d) {
      if (!devices.any((x) => x.id == d.id)) {
        devices.add(d);
        notifyListeners();
      }
    }, onError: (_) {
      if (!comp.isCompleted) comp.complete(devices);
    });

    Future.delayed(timeout, () async {
      await _scan?.cancel();
      scanning = false;
      notifyListeners();
      if (!comp.isCompleted) comp.complete(devices);
    });

    return comp.future;
  }

  int _parseHr(List<int> data) {
    if (data.isEmpty) return 0;
    final f = data[0];
    final is16 = (f & 0x01) != 0;
    if (is16) {
      if (data.length < 3) return 0;
      return data[1] | (data[2] << 8);
    }
    if (data.length < 2) return 0;
    return data[1];
  }

  Future<void> connect(String id, String name, OptimiserState opt) async {
    _conn?.cancel();
    _hr?.cancel();

    _conn = _ble.connectToDevice(id: id).listen((event) {
      if (event.connectionState == DeviceConnectionState.connected) {
        connectedId = id;
        connectedName = name.isEmpty ? "(unknown)" : name;
        notifyListeners();

        final hrChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: hrService,
          characteristicId: hrMeasurement,
        );

        _hr = _ble.subscribeToCharacteristic(hrChar).listen((data) {
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
    await _hr?.cancel();
    await _conn?.cancel();
    connectedId = null;
    connectedName = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _scan?.cancel();
    _conn?.cancel();
    _hr?.cancel();
    super.dispose();
  }
}

// =============================================================
// UI (unchanged except dropdown default)
// =============================================================
class OptimiserDashboard extends StatelessWidget {
  const OptimiserDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final opt = context.watch<OptimiserState>();
    final ble = context.watch<BleManager>();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Physiological Optimiser"),
        leading: IconButton(
          icon: Icon(
            ble.connectedId == null
                ? Icons.bluetooth
                : Icons.bluetooth_connected,
          ),
          onPressed: () => _openBleSheet(context),
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            opt.rhythmAdvice,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: opt.rhythmColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text("HR: ${opt.hr.toStringAsFixed(0)} bpm"),

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

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Feedback: "),
              DropdownButton<FeedbackMode>(
                value: opt.feedbackMode,
                items: const [
                  DropdownMenuItem(
                    value: FeedbackMode.notification,
                    child: Text("System Banner"),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) opt.setFeedbackMode(v);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(height: 200, child: HrGraph(opt: opt)),
          const SizedBox(height: 12),
          if (ble.connectedName != null)
            Text("Connected: ${ble.connectedName}"),
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
      builder: (_) =>
          ChangeNotifierProvider.value(value: ble, child: const _BleBottomSheet()),
    );
  }
}

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
    _scan();
  }

  Future<void> _scan() async {
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
            Row(children: [
              const Icon(Icons.bluetooth),
              const SizedBox(width: 8),
              Text(
                ble.scanning ? "Scanning…" : "Bluetooth Devices",
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (ble.connectedId != null)
                IconButton(
                  icon: const Icon(Icons.link_off),
                  onPressed: () => ble.disconnect(),
                ),
            ]),
            const SizedBox(height: 12),
            Flexible(
              child: devices.isEmpty
                  ? const Text(
                      "No devices found.\nEnsure HR strap is on.",
                      textAlign: TextAlign.center,
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final d = devices[i];
                        final name = d.name.isNotEmpty ? d.name : "(unknown)";
                        return ListTile(
                          title: Text(name),
                          subtitle: Text(d.id),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            final opt = context.read<OptimiserState>();
                            await ble.connect(d.id, name, opt);
                            if (mounted) Navigator.pop(context);
                          },
                        );
                      },
                    ),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _scan,
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

// =============================================================
// GRAPH (unchanged)
// =============================================================
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

    double minY = 50, maxY = 180;

    if (points.isNotEmpty) {
      minY = points.map((p) => p.y).reduce((a, b) => a < b ? a : b) - 5;
      maxY = points.map((p) => p.y).reduce((a, b) => a > b ? a : b) + 5;

      if (minY < 40) minY = 40;
      if (maxY < minY + 10) maxY = minY + 10;
    }

    final maxX = points.isEmpty ? 1 : (points.length - 1).toDouble();

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
