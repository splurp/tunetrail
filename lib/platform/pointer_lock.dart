import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Minimal native cursor control for desktop "mouse look": read the global
/// cursor position and warp it, so the pointer can be kept centred while the
/// player turns the camera with relative mouse movement.
///
/// Windows: user32 GetCursorPos/SetCursorPos. Linux (X11 / XWayland):
/// libX11 XQueryPointer/XWarpPointer. Other platforms: unsupported (mouse
/// look still works until the cursor reaches the window edge).
abstract class CursorControl {
  static CursorControl? _instance;
  static CursorControl? get instance {
    if (_instance != null) return _instance;
    try {
      if (Platform.isWindows) return _instance = _WinCursor();
      if (Platform.isLinux) return _instance = _X11Cursor();
    } catch (_) {
      // Library not available (e.g. pure Wayland): no warping.
    }
    return null;
  }

  /// Global (screen) cursor position, or null if unknown.
  (int, int)? position();

  /// Moves the cursor to a global (screen) position.
  void warp(int x, int y);
}

// ------------------------------------------------------------------ Windows
final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

class _WinCursor extends CursorControl {
  _WinCursor() {
    final user32 = DynamicLibrary.open('user32.dll');
    _get = user32.lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>('GetCursorPos');
    _set = user32.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('SetCursorPos');
  }
  late final int Function(Pointer<_Point>) _get;
  late final int Function(int, int) _set;

  @override
  (int, int)? position() {
    final p = calloc<_Point>();
    try {
      if (_get(p) == 0) return null;
      return (p.ref.x, p.ref.y);
    } finally {
      calloc.free(p);
    }
  }

  @override
  void warp(int x, int y) => _set(x, y);
}

// -------------------------------------------------------------------- Linux
class _X11Cursor extends CursorControl {
  _X11Cursor() {
    final x11 = DynamicLibrary.open('libX11.so.6');
    final open = x11.lookupFunction<Pointer Function(Pointer<Utf8>), Pointer Function(Pointer<Utf8>)>('XOpenDisplay');
    _display = open(nullptr);
    if (_display == nullptr) throw StateError('no X display');
    final root = x11.lookupFunction<UnsignedLong Function(Pointer), int Function(Pointer)>('XDefaultRootWindow');
    _root = root(_display);
    _query = x11.lookupFunction<
        Int32 Function(Pointer, UnsignedLong, Pointer<UnsignedLong>, Pointer<UnsignedLong>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>,
            Pointer<Int32>, Pointer<Uint32>),
        int Function(Pointer, int, Pointer<UnsignedLong>, Pointer<UnsignedLong>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>,
            Pointer<Uint32>)>('XQueryPointer');
    _warp = x11.lookupFunction<Int32 Function(Pointer, UnsignedLong, UnsignedLong, Int32, Int32, Uint32, Uint32, Int32, Int32),
        int Function(Pointer, int, int, int, int, int, int, int, int)>('XWarpPointer');
    _flush = x11.lookupFunction<Int32 Function(Pointer), int Function(Pointer)>('XFlush');
  }
  late final Pointer _display;
  late final int _root;
  late final int Function(Pointer, int, Pointer<UnsignedLong>, Pointer<UnsignedLong>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>,
      Pointer<Int32>, Pointer<Uint32>) _query;
  late final int Function(Pointer, int, int, int, int, int, int, int, int) _warp;
  late final int Function(Pointer) _flush;

  @override
  (int, int)? position() {
    final rootRet = calloc<UnsignedLong>(), child = calloc<UnsignedLong>();
    final rx = calloc<Int32>(), ry = calloc<Int32>(), wx = calloc<Int32>(), wy = calloc<Int32>();
    final mask = calloc<Uint32>();
    try {
      if (_query(_display, _root, rootRet, child, rx, ry, wx, wy, mask) == 0) return null;
      return (rx.value, ry.value);
    } finally {
      for (final p in [rootRet, child, rx, ry, wx, wy, mask]) {
        calloc.free(p);
      }
    }
  }

  @override
  void warp(int x, int y) {
    _warp(_display, 0, _root, 0, 0, 0, 0, x, y);
    _flush(_display);
  }
}
