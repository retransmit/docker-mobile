import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../storage/credential_store.dart';
import '../storage/profile_store.dart';
import '../transport/connection_config.dart';
import '../transport/ssh/host_key.dart';
import '../transport/ssh/ssh_transport.dart';
import '../transport/tls_security.dart';
import '../transport/transport.dart';
import '../ui/home_screen.dart';

/// Establishes a transport from a saved [profile] and navigates to the home
/// screen. The only place the SSH host-key TOFU dialog lives.
Future<void> launchConnection(BuildContext context, WidgetRef ref, ConnectionProfile profile) async {
  switch (profile.kind) {
    case ConnectionKind.agent:
      final a = profile.agent!;
      ref.read(transportProvider.notifier).state =
          AgentConnectionConfig(baseUri: Uri.parse(a.baseUri), token: a.token).build();
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
    case ConnectionKind.tls:
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      final t = profile.tls!;
      final Transport transport;
      try {
        transport = TlsConnectionConfig(
          host: t.host, port: t.port,
          clientCertPem: t.clientCertPem, clientKeyPem: t.clientKeyPem,
          caPem: t.caPem, insecure: t.insecure,
        ).build();
      } on TlsConfigException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Invalid certificate: ${e.message}')));
        return;
      }
      ref.read(transportProvider.notifier).state = transport;
      navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
    case ConnectionKind.ssh:
      await _launchSsh(context, ref, profile);
  }
}

Future<void> _launchSsh(BuildContext context, WidgetRef ref, ConnectionProfile profile, {String? overridePin}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final ssh = profile.ssh!;
  final pin = overridePin ?? ssh.pinnedHostKey;
  final creds = SshCredentials(
    host: ssh.host, port: ssh.port, username: ssh.username, authMethod: ssh.authMethod,
    password: ssh.password, privateKeyPem: ssh.privateKeyPem, passphrase: ssh.passphrase, pinnedHostKey: pin,
  );
  final conn = ref.read(sshConnectionFactoryProvider)(creds);
  String? presented;
  var mismatch = false;
  bool verifier(String fp) {
    presented = fp;
    if (verifyHostKey(pin, fp) == HostKeyVerdict.mismatch) {
      mismatch = true;
      return false;
    }
    return true;
  }

  try {
    await conn.connect(verifyHostKey: verifier);
  } catch (e) {
    await conn.close();
    if (mismatch && presented != null) {
      if (!context.mounted) return;
      final trust = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Host key changed'),
          content: const Text(
              'The server host key does not match the pinned key. This could be a man-in-the-middle attack. Trust the new key only if you expected this change.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Trust new key')),
          ],
        ),
      );
      if (trust == true && context.mounted) {
        await _launchSsh(context, ref, profile, overridePin: presented);
      }
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text('Connection failed: $e')));
    return;
  }

  // The originating widget (and its ref) may have been disposed during the
  // handshake; don't read a dead ref — and don't leak the live SSH client.
  if (!context.mounted) {
    await conn.close();
    return;
  }
  final newPin = pin ?? presented;
  if (newPin != ssh.pinnedHostKey) {
    await ref.read(profileStoreProvider).update(profile.copyWith(
          ssh: SshCredentials(
            host: ssh.host, port: ssh.port, username: ssh.username, authMethod: ssh.authMethod,
            password: ssh.password, privateKeyPem: ssh.privateKeyPem, passphrase: ssh.passphrase, pinnedHostKey: newPin,
          ),
        ));
    if (!context.mounted) {
      await conn.close();
      return;
    }
    ref.invalidate(profilesProvider);
  }
  ref.read(transportProvider.notifier).state = SshTransport(openDuplex: conn.openChannel);
  navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
}
