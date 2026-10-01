import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _GetStdHandleNative = IntPtr Function(Uint32);
typedef _GetStdHandleDart = int Function(int);
typedef _GetModeNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetModeDart = int Function(int, Pointer<Uint32>);
typedef _SetModeNative = Int32 Function(IntPtr, Uint32);
typedef _SetModeDart = int Function(int, int);

/// Turns on virtual-terminal (ANSI) input and output for the Windows console.
///
/// Dart reads the classic Windows console without arrow keys, and PowerShell
/// 5 does not interpret ANSI colors or cursor movement until a program asks.
/// With these two flags set, arrows arrive as the usual `ESC [ A` sequences
/// and the prompts and colors work like on macOS and Linux.
///
/// Everything here is best effort: on any failure (not Windows, not a real
/// console, an old Windows) [ready] stays false and the numbered prompts are
/// used instead.
class WindowsConsole {
  WindowsConsole._(this.ready, this._restore);

  /// Both ANSI input and output are on.
  final bool ready;
  final void Function() _restore;

  static const _enableVirtualTerminalProcessing = 0x0004;
  static const _enableVirtualTerminalInput = 0x0200;
  static const _stdInput = 0xFFFFFFF6; // STD_INPUT_HANDLE  (-10)
  static const _stdOutput = 0xFFFFFFF5; // STD_OUTPUT_HANDLE (-11)

  /// A handle meaning no ANSI support, used when enabling fails.
  static final WindowsConsole unavailable = WindowsConsole._(false, () {});

  /// Enables ANSI input/output. Call [restore] before exiting.
  static WindowsConsole enable() {
    if (!Platform.isWindows || !stdin.hasTerminal || !stdout.hasTerminal) {
      return unavailable;
    }
    try {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final getStdHandle =
          kernel.lookupFunction<_GetStdHandleNative, _GetStdHandleDart>(
              'GetStdHandle');
      final getMode =
          kernel.lookupFunction<_GetModeNative, _GetModeDart>('GetConsoleMode');
      final setMode =
          kernel.lookupFunction<_SetModeNative, _SetModeDart>('SetConsoleMode');

      final hIn = getStdHandle(_stdInput);
      final hOut = getStdHandle(_stdOutput);
      final buffer = calloc<Uint32>();
      try {
        if (getMode(hIn, buffer) == 0) return unavailable;
        final oldIn = buffer.value;
        if (getMode(hOut, buffer) == 0) return unavailable;
        final oldOut = buffer.value;

        final outOk =
            setMode(hOut, oldOut | _enableVirtualTerminalProcessing) != 0;
        final inOk = setMode(hIn, oldIn | _enableVirtualTerminalInput) != 0;

        void restore() {
          try {
            setMode(hIn, oldIn);
            setMode(hOut, oldOut);
          } on Object {
            // Nothing sensible to do while exiting.
          }
        }

        if (!inOk || !outOk) {
          restore();
          return unavailable;
        }
        return WindowsConsole._(true, restore);
      } finally {
        calloc.free(buffer);
      }
    } on Object {
      return unavailable;
    }
  }

  /// Puts the console modes back as they were.
  void restore() => _restore();
}
