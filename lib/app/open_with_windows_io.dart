import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'open_with_wire.dart';

/// Windows single-instance + file handoff over a named pipe.
///
/// Only reached when `Platform.isWindows` is true. CreateMutexW is not
/// exposed by win32 6.x, so that one call uses a small dart:ffi lookup;
/// every pipe/file call goes through package:win32. The lookup is lazy,
/// so importing this file on Linux never touches kernel32.

final Pointer<Void> _invalidHandle = Pointer<Void>.fromAddress(-1);

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

typedef _CreateMutexNative = Pointer<Void> Function(
    Pointer<Void>, Int32, Pointer<Utf16>);
typedef _CreateMutexDart = Pointer<Void> Function(
    Pointer<Void>, int, Pointer<Utf16>);

final _createMutex = _kernel32.lookupFunction<_CreateMutexNative,
    _CreateMutexDart>('CreateMutexW');

Pointer<Void>? _mutex;
bool _mutexAlreadyExisted = false;
ReceivePort? _receivePort;

/// True when the running owner accepted the payload (or focus request).
Future<bool> windowsOpenHandoff(List<String> paths) async {
  if (!Platform.isWindows) return false;
  if (!_acquireMutex()) return false;
  if (!_mutexAlreadyExisted) return false;
  final payload = encodeWindowsOpenPipeBytes(paths, focus: paths.isEmpty);
  if (payload.isEmpty) return false;
  if (await _writeToPipe(payload)) return true;
  // The owner may still be spinning up its pipe server; retry once.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  return _writeToPipe(payload);
}

/// True when this process acquired the mutex and serves the handoff
/// pipe; false when another instance already owns it.
Future<bool> windowsOpenServe({
  required void Function(List<String> paths) onOpen,
  required void Function() onFocus,
}) async {
  if (!Platform.isWindows) return false;
  if (!_acquireMutex()) return true; // Unknown state: boot without serving.
  if (_mutexAlreadyExisted) return false;
  if (_receivePort != null) return true;
  final receive = ReceivePort();
  _receivePort = receive;
  receive.listen((message) {
    if (message is! List) return;
    final values = message.whereType<String>().toList();
    final focus = values.contains(windowsFocusMarker);
    final paths =
        values.where((value) => value != windowsFocusMarker).toList();
    if (paths.isNotEmpty) onOpen(paths);
    if (focus || paths.isNotEmpty) onFocus();
  });
  await Isolate.spawn(_pipeServerMain, receive.sendPort);
  return true;
}

/// Creates (or opens) the process-wide mutex.
bool _acquireMutex() {
  if (_mutex != null) return true;
  final name = windowsMutexName.toNativeUtf16();
  try {
    final handle = _createMutex(nullptr, 0, name);
    final error = GetLastError();
    if (handle == nullptr || handle == _invalidHandle) return false;
    _mutex = handle;
    _mutexAlreadyExisted = error == ERROR_ALREADY_EXISTS;
    return true;
  } finally {
    malloc.free(name);
  }
}

Future<bool> _writeToPipe(List<int> payload) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    final handle = _openPipeForWrite();
    if (handle != null) {
      try {
        return _writeAll(handle, payload);
      } finally {
        CloseHandle(handle);
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

HANDLE? _openPipeForWrite() {
  final name = windowsPipeName.toNativeUtf16();
  try {
    final result = CreateFile(
      PCWSTR(name),
      GENERIC_WRITE,
      FILE_SHARE_NONE,
      null,
      OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL,
      null,
    );
    final handle = result.value;
    if (handle.address == 0 || errorIsInvalidHandle(handle)) return null;
    return handle;
  } catch (_) {
    return null;
  } finally {
    malloc.free(name);
  }
}

bool errorIsInvalidHandle(HANDLE handle) =>
    handle.address == _invalidHandle.address;

bool _writeAll(HANDLE handle, List<int> payload) {
  final buffer = calloc<Uint8>(payload.length);
  final written = calloc<Uint32>();
  try {
    buffer.asTypedList(payload.length).setAll(0, payload);
    final result = WriteFile(handle, buffer, payload.length, written, null);
    return result.value && written.value == payload.length;
  } catch (_) {
    return false;
  } finally {
    calloc.free(written);
    calloc.free(buffer);
  }
}

void _pipeServerMain(SendPort port) {
  while (true) {
    final handle = _createServerPipe();
    if (handle == null) {
      sleep(const Duration(milliseconds: 250));
      continue;
    }
    try {
      final connected = ConnectNamedPipe(handle, null);
      if (!connected.value &&
          connected.error != ERROR_PIPE_CONNECTED) {
        continue;
      }
      final text = _readPipeText(handle);
      final payload = decodeWindowsOpenPipePayload(text);
      if (!payload.isEmpty) {
        port.send(<String>[
          if (payload.focusRequested) windowsFocusMarker,
          ...payload.paths,
        ]);
      }
      DisconnectNamedPipe(handle);
    } catch (_) {
      // Broken connection: drop it and wait for the next launch.
    } finally {
      CloseHandle(handle);
    }
  }
}

HANDLE? _createServerPipe() {
  final name = windowsPipeName.toNativeUtf16();
  try {
    final handle = CreateNamedPipe(
      PCWSTR(name),
      PIPE_ACCESS_INBOUND,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
      1, // one instance at a time
      4096,
      4096,
      0,
      null,
    );
    if (handle.address == 0 || errorIsInvalidHandle(handle)) return null;
    return handle;
  } catch (_) {
    return null;
  } finally {
    malloc.free(name);
  }
}

String _readPipeText(HANDLE handle) {
  final bytes = BytesBuilder(copy: false);
  final buffer = calloc<Uint8>(4096);
  final read = calloc<Uint32>();
  try {
    while (true) {
      read.value = 0;
      final result = ReadFile(handle, buffer, 4096, read, null);
      final count = read.value;
      if (!result.value || count == 0) break;
      bytes.add(buffer.asTypedList(count));
    }
  } catch (_) {
    // Fall through with whatever arrived.
  } finally {
    calloc.free(read);
    calloc.free(buffer);
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}
