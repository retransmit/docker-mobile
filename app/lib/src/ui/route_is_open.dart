import 'package:flutter/widgets.dart';

/// Whether the screen that [context] belongs to is still open, that is,
/// whether its route is still on the navigator.
///
/// A popped route keeps its widgets mounted until its exit transition ends,
/// so `mounted` alone cannot tell an action that waited for something whether
/// its screen was closed in the meantime; a pop at that point closes the
/// screen underneath instead. Needs a mounted [context].
bool routeIsOpen(BuildContext context) => ModalRoute.of(context)?.isActive ?? false;
