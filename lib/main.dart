import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

void main() {
  runApp(const ArduinoScopeApp());
}

// ─── Colors ───────────────────────────────────────────────────
const kBgDark    = Color(0xFF0A0C0F);
const kBgPanel   = Color(0xFF0F1318);
const kBorder    = Color(0xFF1E2830);
const kGreen     = Color(0xFF00E5A0);
const kCyan      = Color(0xFF00B8D4);
const kAmber     = Color(0xFFFFB300);
const kRed       = Color(0xFFFF4F5E);
const kTextMain  = Color(0xFFC8D8E8);
const kTextMuted = Color(0xFF4A6070);

// ─── Log Entry ────────────────────────────────────────────────
enum LogType { rx, tx, sys, err }

class LogEntry {
  final String message;
  final LogType type;
  final DateTime time;
  LogEntry(this.message, this.type) : time = DateTime.now();

  Color get color {
    switch (type) {
      case LogType.rx:  return kGreen;
      case LogType.tx:  return kCyan;
      case LogType.sys: return kAmber;
      case LogType.err: return kRed;
    }
  }

  String get prefix {
    switch (type) {
      case LogType.rx:  return 'RX';
      case LogType.tx:  return 'TX';
      case LogType.sys: return '>>';
      case LogType.err: return '!!';
    }
  }

  String toPlainString(bool withTs) {
    final ts = withTs
        ? DateFormat('HH:mm:ss.SSS').format(time) + '  '
        : '';
    return '$ts$prefix  $message';
  }
}

// ─── Baud Rates ───────────────────────────────────────────────
const baudRates = [
  300, 1200, 2400, 4800, 9600, 14400,
  19200, 38400, 57600, 74880, 115200,
  230400, 250000, 500000, 1000000, 2000000,
];

// ─── EOL Options ──────────────────────────────────────────────
const eolLabels = ['No EOL', r'\n', r'\r', r'\r\n'];
const eolValues = ['', '\n', '\r', '\r\n'];

// ══════════════════════════════════════════════════════════════
//  APP
// ══════════════════════════════════════════════════════════════
class ArduinoScopeApp extends StatelessWidget {
  const ArduinoScopeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ArduinoScope',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: kBgDark,
        colorScheme: const ColorScheme.dark(
          primary: kGreen,
          secondary: kCyan,
          surface: kBgPanel,
        ),
        fontFamily: 'monospace',
      ),
      home: const SerialMonitorPage(),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  MAIN PAGE
// ══════════════════════════════════════════════════════════════
class SerialMonitorPage extends StatefulWidget {
  const SerialMonitorPage({super.key});
  @override
  State<SerialMonitorPage> createState() => _SerialMonitorPageState();
}

class _SerialMonitorPageState extends State<SerialMonitorPage> {
  // Serial state
  UsbPort?   _port;
  bool       _connected   = false;
  StreamSubscription? _sub;
  String     _buffer      = '';

  // Settings
  int    _baudIdx      = 4;   // 9600
  int    _eolIdx       = 1;   // \n
  bool   _showTs       = true;
  bool   _autoScroll   = true;

  // Log
  final List<LogEntry> _log = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _sendCtrl = TextEditingController();
  final FocusNode _sendFocus = FocusNode();

  // Stats
  int _rxBytes = 0;
  int _txBytes = 0;

  @override
  void initState() {
    super.initState();
    _addLog('ArduinoScope ready — plug board via OTG and tap Connect', LogType.sys);
    _addLog('Supports: ESP8266, ESP32, Arduino Nano/Uno/Mega', LogType.sys);

    // Listen for USB attach/detach
    UsbSerial.usbEventStream?.listen((UsbEvent event) {
      if (event.event == UsbEvent.ACTION_USB_ATTACHED) {
        _addLog('USB device attached!', LogType.sys);
      } else if (event.event == UsbEvent.ACTION_USB_DETACHED) {
        if (_connected) {
          _disconnect();
          _addLog('USB device detached', LogType.err);
        }
      }
    });
  }

  @override
  void dispose() {
    _disconnect();
    _scroll.dispose();
    _sendCtrl.dispose();
    _sendFocus.dispose();
    super.dispose();
  }

  // ── Log ────────────────────────────────────────────────────
  void _addLog(String msg, LogType type) {
    setState(() {
      _log.add(LogEntry(msg, type));
      if (_log.length > 500) _log.removeAt(0);
    });
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  // ── Connect ────────────────────────────────────────────────
  Future<void> _connect() async {
    List<UsbDevice> devices = await UsbSerial.listDevices();

    if (devices.isEmpty) {
      _addLog('No USB device found — check OTG cable', LogType.err);
      return;
    }

    _addLog('Found ${devices.length} device(s) — connecting…', LogType.sys);

    for (final device in devices) {
      try {
        UsbPort? port = await device.create();
        if (port == null) continue;

        bool opened = await port.open();
        if (!opened) { await port.close(); continue; }

        await port.setDTR(true);
        await port.setRTS(true);
        await port.setPortParameters(
          baudRates[_baudIdx],
          UsbPort.DATABITS_8,
          UsbPort.STOPBITS_1,
          UsbPort.PARITY_NONE,
        );

        _port = port;

        // Start reading
        _sub = port.inputStream?.listen(
          _onData,
          onError: (e) {
            _addLog('Read error: $e', LogType.err);
            _disconnect();
          },
          onDone: () {
            if (_connected) {
              _addLog('Device disconnected', LogType.err);
              _disconnect();
            }
          },
        );

        setState(() => _connected = true);
        _addLog(
          'Connected @ ${baudRates[_baudIdx]} baud | '
          '${device.productName ?? "VID:${device.vid}"}',
          LogType.sys,
        );
        return;
      } catch (e) {
        _addLog('Error: $e', LogType.err);
        continue;
      }
    }

    _addLog('Failed to open any device', LogType.err);
  }

  void _onData(Uint8List data) {
    _rxBytes += data.length;
    _buffer += String.fromCharCodes(data);
    final lines = _buffer.split('\n');
    _buffer = lines.removeLast();
    for (final line in lines) {
      final clean = line.trimRight();
      if (clean.isNotEmpty) _addLog(clean, LogType.rx);
    }
  }

  // ── Disconnect ─────────────────────────────────────────────
  Future<void> _disconnect() async {
    await _sub?.cancel();
    _sub = null;
    try { await _port?.close(); } catch (_) {}
    _port = null;
    setState(() => _connected = false);
    _addLog('Disconnected', LogType.sys);
  }

  // ── Send ───────────────────────────────────────────────────
  Future<void> _send() async {
    final text = _sendCtrl.text;
    if (text.isEmpty || !_connected || _port == null) return;

    final eol = eolValues[_eolIdx];
    final payload = text + eol;

    try {
      await _port!.write(Uint8List.fromList(payload.codeUnits));
      _txBytes += payload.length;
      _addLog(text, LogType.tx);
      _sendCtrl.clear();
    } catch (e) {
      _addLog('Send error: $e', LogType.err);
    }
  }

  // ── Clear ──────────────────────────────────────────────────
  void _clear() {
    setState(() => _log.clear());
    _addLog('Log cleared', LogType.sys);
  }

  // ── Export ─────────────────────────────────────────────────
  Future<void> _export() async {
    if (_log.isEmpty) {
      _snack('Nothing to export');
      return;
    }
    final content = _log.map((e) => e.toPlainString(_showTs)).join('\n');
    final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final fileName = 'arduino_log_$ts.txt';

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(content);
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Arduino Serial Log',
      );
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
        backgroundColor: kBgPanel,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgDark,
      body: SafeArea(
        child: Column(children: [
          _buildHeader(),
          _buildToolbar(),
          Expanded(child: _buildLog()),
          _buildSendBar(),
          _buildConnectBar(),
        ]),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      height: 52,
      color: kBgPanel,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        // Logo
        RichText(text: const TextSpan(
          style: TextStyle(fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.bold),
          children: [
            TextSpan(text: 'Arduino', style: TextStyle(color: kGreen)),
            TextSpan(text: 'Scope',   style: TextStyle(color: Colors.white)),
          ],
        )),
        const SizedBox(width: 10),
        Container(width: 1, height: 20, color: kBorder),
        const SizedBox(width: 10),
        Text(
          'SERIAL MONITOR',
          style: TextStyle(
            fontSize: 9, letterSpacing: 2,
            color: kTextMuted, fontFamily: 'monospace',
          ),
        ),
        const Spacer(),
        // Status dot
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _connected ? kGreen : kTextMuted,
            boxShadow: _connected ? [BoxShadow(color: kGreen.withOpacity(.6), blurRadius: 8)] : null,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _connected ? 'CONNECTED' : 'DISCONNECTED',
          style: TextStyle(
            fontSize: 10, letterSpacing: 1.5,
            color: _connected ? kGreen : kTextMuted,
            fontFamily: 'monospace',
          ),
        ),
      ]),
    );
  }

  // ── Toolbar ────────────────────────────────────────────────
  Widget _buildToolbar() {
    return Container(
      height: 46,
      color: kBgPanel,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: [
        // Baud
        Text('BAUD', style: TextStyle(fontSize: 9, color: kTextMuted, letterSpacing: 2)),
        const SizedBox(width: 6),
        _styledDropdown(
          value: baudRates[_baudIdx].toString(),
          items: baudRates.map((b) => b.toString()).toList(),
          onChanged: (v) => setState(() => _baudIdx = baudRates.indexOf(int.parse(v!))),
          width: 100,
        ),
        const SizedBox(width: 8),
        Container(width: 1, height: 20, color: kBorder),
        const SizedBox(width: 8),
        // Timestamps
        Text('TS', style: TextStyle(fontSize: 9, color: kTextMuted, letterSpacing: 2)),
        Transform.scale(
          scale: 0.75,
          child: Switch(
            value: _showTs,
            onChanged: (v) => setState(() => _showTs = v),
            activeColor: kGreen,
            inactiveThumbColor: kTextMuted,
            inactiveTrackColor: kBorder,
          ),
        ),
        // Autoscroll
        Text('↓', style: TextStyle(fontSize: 13, color: kTextMuted)),
        Transform.scale(
          scale: 0.75,
          child: Switch(
            value: _autoScroll,
            onChanged: (v) => setState(() => _autoScroll = v),
            activeColor: kGreen,
            inactiveThumbColor: kTextMuted,
            inactiveTrackColor: kBorder,
          ),
        ),
        const Spacer(),
        // Stats
        Text(
          'RX:${_fmtBytes(_rxBytes)}  TX:${_fmtBytes(_txBytes)}',
          style: TextStyle(fontSize: 9, color: kTextMuted, fontFamily: 'monospace'),
        ),
        const SizedBox(width: 8),
        // Clear
        _toolBtn('CLR', kRed, _clear),
        // Export
        _toolBtn('EXP', kAmber, _export),
      ]),
    );
  }

  Widget _toolBtn(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(.4)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 10, color: color,
              fontFamily: 'monospace', letterSpacing: 1),
        ),
      ),
    );
  }

  // ── Log Output ─────────────────────────────────────────────
  Widget _buildLog() {
    return Container(
      color: kBgDark,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: _log.length,
        itemBuilder: (ctx, i) {
          final entry = _log[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timestamp
                if (_showTs) ...[
                  Text(
                    DateFormat('HH:mm:ss.SSS').format(entry.time),
                    style: const TextStyle(
                      fontSize: 11, color: kTextMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // Direction badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(color: entry.color.withOpacity(.4)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    entry.prefix,
                    style: TextStyle(
                      fontSize: 10, color: entry.color,
                      fontFamily: 'monospace', fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Message
                Expanded(
                  child: Text(
                    entry.message,
                    style: TextStyle(
                      fontSize: 12,
                      color: entry.type == LogType.rx ? kTextMain : entry.color,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Send Bar ───────────────────────────────────────────────
  Widget _buildSendBar() {
    return Container(
      height: 50,
      color: kBgPanel,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(children: [
        // TX label
        Text('TX', style: TextStyle(fontSize: 9, color: kTextMuted, letterSpacing: 2)),
        const SizedBox(width: 8),
        // Input
        Expanded(
          child: TextField(
            controller: _sendCtrl,
            focusNode: _sendFocus,
            enabled: _connected,
            onSubmitted: (_) => _send(),
            style: const TextStyle(
              fontSize: 13, color: kGreen, fontFamily: 'monospace',
            ),
            decoration: InputDecoration(
              hintText: 'Type command…',
              hintStyle: TextStyle(color: kTextMuted, fontSize: 12),
              filled: true,
              fillColor: kBgDark,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: kBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: kBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: kGreen),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: kBorder.withOpacity(.4)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        // EOL
        _styledDropdown(
          value: eolLabels[_eolIdx],
          items: eolLabels,
          onChanged: (v) => setState(() => _eolIdx = eolLabels.indexOf(v!)),
          width: 72,
        ),
        const SizedBox(width: 6),
        // Send button
        GestureDetector(
          onTap: _connected ? _send : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(
                color: _connected ? kGreen : kBorder,
              ),
              borderRadius: BorderRadius.circular(3),
              color: _connected ? kGreen.withOpacity(.1) : Colors.transparent,
            ),
            child: Text(
              'SEND',
              style: TextStyle(
                fontSize: 12, fontFamily: 'monospace',
                letterSpacing: 1.5, fontWeight: FontWeight.bold,
                color: _connected ? kGreen : kBorder,
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Connect Bar ────────────────────────────────────────────
  Widget _buildConnectBar() {
    final isConn = _connected;
    return Container(
      height: 50,
      color: kBgPanel,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: GestureDetector(
        onTap: isConn ? _disconnect : _connect,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            border: Border.all(color: isConn ? kRed : kGreen),
            borderRadius: BorderRadius.circular(4),
            color: isConn
                ? kRed.withOpacity(.1)
                : kGreen.withOpacity(.08),
          ),
          child: Center(
            child: Text(
              isConn ? '⏏  DISCONNECT' : '⏵  CONNECT',
              style: TextStyle(
                fontSize: 14,
                color: isConn ? kRed : kGreen,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────
  Widget _styledDropdown({
    required String value,
    required List<String> items,
    required void Function(String?) onChanged,
    double width = 100,
  }) {
    return Container(
      width: width,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: kBgDark,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(3),
      ),
      child: DropdownButton<String>(
        value: value,
        items: items.map((e) => DropdownMenuItem(
          value: e,
          child: Text(e, style: const TextStyle(
            fontSize: 12, color: kTextMain, fontFamily: 'monospace',
          )),
        )).toList(),
        onChanged: onChanged,
        dropdownColor: kBgPanel,
        underline: const SizedBox(),
        isDense: true,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: kTextMain),
        icon: Icon(Icons.keyboard_arrow_down, size: 16, color: kTextMuted),
      ),
    );
  }

  String _fmtBytes(int n) {
    if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(1)}M';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)}K';
    return '$n B';
  }
}
