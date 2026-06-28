import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/socket_service.dart';
import '../services/storage_service.dart';

class DeviceInfoBottomSheet extends StatefulWidget {
  const DeviceInfoBottomSheet({super.key, required this.onReconfigure});

  final VoidCallback onReconfigure;

  @override
  State<DeviceInfoBottomSheet> createState() => _DeviceInfoBottomSheetState();
}

class _DeviceInfoBottomSheetState extends State<DeviceInfoBottomSheet> {
  String _connectedUrl = '';
  String _deviceId = '';
  String _deviceName = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    final storage = StorageService.instance;
    final url = await storage.loadApiBaseUrl();
    final deviceId = await storage.loadHardwareKey();
    final name = await storage.loadDisplayName();
    if (!mounted) return;
    setState(() {
      _connectedUrl = url ?? '';
      _deviceId = deviceId ?? '';
      _deviceName = name ?? '';
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Device Information',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          if (!_loaded)
            const Center(
              child: CircularProgressIndicator(color: AppConfig.accentOrange),
            )
          else ...[
            _buildInfoRow('Connected URL', _connectedUrl.isEmpty ? '—' : _connectedUrl),
            const SizedBox(height: 14),
            _buildInfoRow('Device ID', _deviceId.isEmpty ? '—' : _deviceId),
            const SizedBox(height: 14),
            _buildInfoRow('Device Name', _deviceName.isEmpty ? '—' : _deviceName),
            const SizedBox(height: 14),
            _buildStatusRow(),
          ],
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onReconfigure();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConfig.accentOrange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Reconfigure',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildStatusRow() {
    return StreamBuilder<bool>(
      stream: SocketService.instance.connectionStream,
      initialData: SocketService.instance.isConnected,
      builder: (context, snapshot) {
        final connected = snapshot.data ?? false;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Device Status',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected ? Colors.green : Colors.red,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  connected ? 'Connected' : 'Disconnected',
                  style: TextStyle(
                    color: connected ? Colors.green : Colors.red,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

Future<void> showDeviceInfoBottomSheet(
  BuildContext context, {
  required VoidCallback onReconfigure,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => DeviceInfoBottomSheet(onReconfigure: onReconfigure),
  );
}
