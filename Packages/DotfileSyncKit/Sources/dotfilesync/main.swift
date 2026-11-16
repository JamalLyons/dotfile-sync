// dotfilesync: the command-line client. Port of crates/dotfilesync-cli/src/main.rs.
// All logic lives in the `CLI` library so tests can run commands in-process.

import CLI
import Darwin

exit(runCLI(Array(CommandLine.arguments.dropFirst()), context: .live()))
