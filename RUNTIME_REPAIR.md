# Runtime repair contract

`repair_runtime_service` separates executable availability, functional verification,
live promotion, and project configuration persistence. Availability alone never
qualifies a command as verified.

LSP verification starts a separate client, completes the initialize exchange, and
stops that client before promotion. The probe client never enters the live manager.
The initialize deadline is five seconds; stop performs the client's bounded
shutdown and process cleanup. Live activation uses a different client.

For test runners, linters, and commands, supported executables receive `--help`
appended to the exact proposed arguments. This exercises argument parsing and
startup without deliberately running a test suite or formatting the project.
It does not prove that a project's tests pass or its source is valid. Unsupported
executables require explicit `probe_args`, a nonempty array of non-mutating probe
arguments appended to the proposed command. Commands are executed as argv, without
a shell; shell pipelines and redirections are not supported. Custom probes are
operator-supplied executable code, not a security sandbox. They must not modify
project files. Probes run in the project directory so project-local dependencies
and configuration remain available.

A nonzero probe exit or five-second timeout fails verification. Processes and
output files belong to a disposable child context; cleanup kills the POSIX process
group and reaps the process. On Windows the platform process-tree cleanup is used.
No probe timer or pipe-reader thread is retained.

After verification, promotion records the previous service, adapter command and
adapter config reference, and in-memory config value before modifying them.
A promotion exception or failed project save unwinds those changes. LSP rollback
stops the candidate and restarts the previous configured client when one existed;
if restart fails, the result explicitly reports incomplete rollback. Reconnection
can interrupt in-flight LSP requests; this is not a lossless client handoff.
Errors identify verification, promotion, or persistence as the failing phase.

Successful project persistence is an intentional operator configuration change.
Normal runtime disposal restores the original adapter fields and session config,
clears live services, and stops the repaired LSP client; it does **not** undo a
successful project save. Failed saves rely on Config's atomic-write contract and
restore session values. No-config runner/linter repairs are explicitly reported
as session-only. LSP promotion requires both a manager and config.

Repeated repairs of a service retain one repair lifetime scope, restoring the
original session baseline when that scope is disposed. A failed subsequent repair
restores the immediately preceding session state.
