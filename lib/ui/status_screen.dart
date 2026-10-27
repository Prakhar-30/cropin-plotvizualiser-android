import 'package:flutter/material.dart';

import 'theme.dart';

/// Full-page state shown while the feature starts, or when it cannot.
///
/// These are the first thing a host app's user sees when the entry point is
/// tapped, so they carry the same header as the rest of the planning screens
/// rather than a bare spinner or a line of text.
class StatusScreen extends StatelessWidget {
  /// A spinner with a short line about what is being waited on.
  const StatusScreen.loading({super.key, required this.title})
      : detail = null,
        icon = null,
        loading = true;

  /// An explanation for why the feature is not available.
  const StatusScreen.notice({super.key, required this.title, required this.detail, this.icon = Icons.info_outline})
      : loading = false;

  final String title;
  final String? detail;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return Scaffold(
      appBar: AppBar(title: const Text('Plot Finder')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(color: GrowColors.primaryTint, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: loading
                    ? const SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(strokeWidth: 3, color: GrowColors.primary),
                      )
                    : Icon(icon, size: 32, color: GrowColors.primary),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: GrowColors.text),
              ),
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, height: 1.43, color: GrowColors.mutedText),
                ),
              ],
              if (!loading && Navigator.of(context).canPop()) ...[
                const SizedBox(height: 24),
                OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Go back')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
