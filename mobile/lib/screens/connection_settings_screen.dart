import 'package:flutter/material.dart';
import '../services/connection_manager.dart';
import '../services/secure_tunnel_client.dart';
import 'qr_scanner_screen.dart';

/// Connection Settings Screen
class ConnectionSettingsScreen extends StatefulWidget {
  const ConnectionSettingsScreen({super.key});

  @override
  State<ConnectionSettingsScreen> createState() => _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState extends State<ConnectionSettingsScreen> {
  String connectionType = 'Controleren...';
  bool isLoading = true;
  Map<String, String>? credentials;

  @override
  void initState() {
    super.initState();
    _loadConnectionInfo();
  }

  Future<void> _loadConnectionInfo() async {
    setState(() => isLoading = true);

    final type = await ConnectionManager.getConnectionType();
    final creds = await TunnelCredentialsStorage.loadCredentials();

    setState(() {
      connectionType = _getConnectionTypeLabel(type);
      credentials = creds;
      isLoading = false;
    });
  }

  String _getConnectionTypeLabel(String type) {
    switch (type) {
      case 'local':
        return 'Lokaal (WiFi)';
      case 'tunnel':
        return 'Remote (Tunnel)';
      default:
        return 'Niet verbonden';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verbinding'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadConnectionInfo,
          ),
        ],
      ),
      body: ListView(
        children: [
          // Connection Status Card
          _buildStatusCard(),

          const SizedBox(height: 16),

          // Hub Credentials Card
          if (credentials != null) _buildCredentialsCard(),

          const SizedBox(height: 16),

          // Privacy Notice
          _buildPrivacyCard(),

          const SizedBox(height: 16),

          // Actions
          _buildActionsCard(),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    IconData icon;
    Color color;

    if (isLoading) {
      icon = Icons.hourglass_empty;
      color = Colors.grey;
    } else if (connectionType.contains('Lokaal')) {
      icon = Icons.wifi;
      color = Colors.green;
    } else if (connectionType.contains('Remote')) {
      icon = Icons.cloud;
      color = Colors.blue;
    } else {
      icon = Icons.cloud_off;
      color = Colors.red;
    }

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(icon, size: 64, color: color),
            const SizedBox(height: 16),
            Text(
              'Verbinding',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              connectionType,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            if (!isLoading && connectionType.contains('Remote'))
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock, size: 16, color: Colors.green),
                    SizedBox(width: 8),
                    Text(
                      'End-to-end versleuteld',
                      style: TextStyle(color: Colors.green, fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCredentialsCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.vpn_key, color: Colors.blue),
                const SizedBox(width: 12),
                Text(
                  'Hub Credentials',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(height: 24),
            _buildInfoRow('Hub ID', credentials!['hubId']!),
            const SizedBox(height: 12),
            _buildInfoRow('Relay', credentials!['relayUrl']!),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _buildPrivacyCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shield, color: Colors.green),
                const SizedBox(width: 12),
                Text(
                  'Privacy Waarborgen',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(height: 24),
            _buildPrivacyItem('Alle data blijft op jouw hub (100% lokaal)'),
            _buildPrivacyItem('End-to-end versleuteld tussen app en hub'),
            _buildPrivacyItem('Cloud relay kan verkeer niet lezen'),
            _buildPrivacyItem('Geen port forwarding nodig'),
          ],
        ),
      ),
    );
  }

  Widget _buildPrivacyItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, size: 16, color: Colors.green),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsCard() {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.qr_code_scanner, color: Colors.blue),
            title: const Text('Scan Hub QR Code'),
            subtitle: const Text('Nieuwe hub toevoegen of opnieuw koppelen'),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: _scanQRCode,
          ),
          const Divider(height: 1),
          if (credentials != null)
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Ontkoppelen'),
              subtitle: const Text('Verwijder hub credentials'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: _disconnect,
            ),
        ],
      ),
    );
  }

  Future<void> _scanQRCode() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const QRScannerScreen()),
    );

    if (result == true) {
      _loadConnectionInfo();
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ontkoppelen?'),
        content: const Text(
          'Weet je zeker dat je de hub wilt ontkoppelen? '
          'Je moet de QR-code opnieuw scannen om opnieuw te verbinden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuleren'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Ontkoppelen'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await TunnelCredentialsStorage.clearCredentials();
      ConnectionManager.disconnect();
      _loadConnectionInfo();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hub ontkoppeld')),
        );
      }
    }
  }
}
