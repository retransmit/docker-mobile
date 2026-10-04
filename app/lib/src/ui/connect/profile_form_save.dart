import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../storage/profile_store.dart';
import '../route_is_open.dart';

/// Save handling shared by the connection forms: write the profile once,
/// then close the editor, returning the profile for "Save & Connect".
mixin ProfileFormSave<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The profile from the form's fields, or null when they do not validate.
  ConnectionProfile? buildProfile();

  /// True when the form edits an existing profile.
  bool get isEditing;

  bool _saving = false;

  /// Saves the profile and closes the editor.
  Future<void> save() async {
    if (_saving) return;
    final p = buildProfile();
    if (p == null) return;
    await _persistOnce(p);
    if (!mounted) return;
    closeRoute(context);
  }

  /// Saves and returns the profile to the Connections list, which connects
  /// and shows the progress or the error.
  Future<void> saveAndConnect() async {
    if (_saving) return;
    final p = buildProfile();
    if (p == null) return;
    await _persistOnce(p);
    if (!mounted) return;
    closeRoute(context, p);
  }

  /// Saves [p]; further taps are ignored from here on (the editor is closing).
  /// A failed save lets the user try again and rethrows.
  Future<void> _persistOnce(ConnectionProfile p) async {
    _saving = true;
    try {
      await _persist(p);
    } catch (_) {
      _saving = false;
      rethrow;
    }
  }

  Future<void> _persist(ConnectionProfile p) async {
    final store = ref.read(profileStoreProvider);
    isEditing ? await store.update(p) : await store.add(p);
    ref.invalidate(profilesProvider);
  }
}
