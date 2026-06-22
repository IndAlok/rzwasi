// Emscripten compatibility shims for rizin symbols that are declared and called
// but never compiled on a wasm target.
//
// rizin 0.9.0 introduced rz_stop_pipe_* in librz/socket/socket.c and emits them
// only in the networking-enabled branch (the #if EMSCRIPTEN guard sets
// NETWORK_DISABLED, and the no-network branch was not given matching stubs).
// rz_signal_sigmask (librz/util/signal.c) is likewise gated behind HAVE_PTHREAD,
// which this build forces to 0. On Emscripten all of those branches are off, so
// the five symbols below are left undefined.
//
// Because we link with -sERROR_ON_UNDEFINED_SYMBOLS=0 the link still succeeds,
// but each missing symbol becomes a stub that aborts when first called. That
// surfaces as an opaque "function signature mismatch" RuntimeError the moment
// analysis runs: core/task.c masks signals around every task, and rz_stop_pipe
// backs the remote protocol. Provide inert equivalents here. The browser has no
// POSIX signals to mask and no sockets to interrupt, so doing nothing is correct.
//
// These are defined in the rizin executable's translation units (not librz), so
// they only satisfy the one binary we actually ship (rizin.js/.wasm).

#ifdef __EMSCRIPTEN__

#include <rz_socket.h>
#include <rz_util.h>
#include <signal.h>
#include <stdlib.h>

RZ_API void rz_signal_sigmask(int how, const sigset_t *newmask, sigset_t *oldmask) {
	(void)how;
	(void)newmask;
	(void)oldmask;
}

RZ_API RzStopPipe *rz_stop_pipe_new(void) {
	// Opaque handle, never dereferenced: returned non-NULL so callers do not
	// mistake it for an allocation failure, and freeable by rz_stop_pipe_free.
	return (RzStopPipe *)malloc(sizeof(int));
}

RZ_API void rz_stop_pipe_free(RzStopPipe *stop_pipe) {
	free(stop_pipe);
}

RZ_API void rz_stop_pipe_stop(RzStopPipe *stop_pipe) {
	(void)stop_pipe;
}

RZ_API RzStopPipeSelectResult rz_stop_pipe_select_single(RzStopPipe *stop_pipe, RzSocket *sock, bool sock_write, ut64 timeout_ms) {
	// No socket I/O in the browser. Report "stopped" so any wait loop in the
	// remote protocol exits at once rather than spinning.
	(void)stop_pipe;
	(void)sock;
	(void)sock_write;
	(void)timeout_ms;
	return RZ_STOP_PIPE_STOPPED;
}

#endif // __EMSCRIPTEN__
