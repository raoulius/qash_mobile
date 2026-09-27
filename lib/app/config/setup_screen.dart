import 'package:flutter/material.dart';
import '../theme.dart';
import 'config_service.dart';
import 'device_config.dart';

/// Pairing codes are 4–12 chars (4 today, 8 once the server sets
/// QASH_PRINT_PAIRING_CODE_LENGTH=8), single-use, valid 15 minutes.
String? validatePairingCode(String? v) {
  final n = v?.trim().length ?? 0;
  return n < 4 || n > 12 ? 'Harus 4–12 karakter' : null;
}

/// Shown on first launch (no saved config). The cashier enters only the
/// pairing code from the backoffice Print Stations page — the server resolves
/// it to a tenant and hands back that tenant's own api_base_url.
class SetupScreen extends StatefulWidget {
  final void Function(DeviceConfig config) onActivated;

  const SetupScreen({super.key, required this.onActivated});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _tokenController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _activate() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    try {
      final config = await ConfigService.activate(_tokenController.text);
      widget.onActivated(config);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Aktivasi Perangkat')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset(AppTheme.logo(context, 'main_logo'), height: 120),
                  const SizedBox(height: 24),
                  Text(
                    'Aktivasi Print Station',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Masukkan token aktivasi dari admin (menu Print Stations di backoffice).',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _tokenController,
                    decoration: const InputDecoration(
                      labelText: 'Token aktivasi',
                      hintText: 'Kode dari halaman Print Stations',
                      border: OutlineInputBorder(),
                    ),
                    autocorrect: false,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 12,
                    validator: validatePairingCode,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _loading ? null : _activate,
                    child: _loading
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Aktifkan'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
