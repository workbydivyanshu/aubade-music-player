/// Non-Windows fallback for the named-pipe handoff.
///
/// The real implementation lives in `open_with_windows_io.dart` and is
/// selected through the conditional import in `open_with.dart`. This
/// stub keeps the shared call sites compilable on every platform.
Future<bool> windowsOpenHandoff(List<String> paths) async => false;

Future<void> windowsOpenServe({
  required void Function(List<String> paths) onOpen,
  required void Function() onFocus,
}) async {}
