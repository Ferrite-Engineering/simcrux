// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Conditional-import shim for the platform file-manager reveal: the io
// build calls `crux_io`'s `revealInFileManager`; the web build no-ops
// (there is no file manager to reveal into).
export 'reveal_tab_file_stub.dart'
    if (dart.library.io) 'reveal_tab_file_io.dart';
