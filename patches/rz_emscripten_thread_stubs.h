/**
 * @file rz_emscripten_thread_stubs.h
 * @brief Type stubs for single-threaded WASM builds
 */

#ifndef RZ_EMSCRIPTEN_THREAD_STUBS_H
#define RZ_EMSCRIPTEN_THREAD_STUBS_H

#ifdef __EMSCRIPTEN__

#include <stdbool.h>

typedef int RZ_TH_TID;
typedef int RZ_TH_LOCK_T;
typedef int RZ_TH_COND_T;
typedef int RZ_TH_SEM_T;
typedef void* RZ_TH_RET_T;
#define RZ_TH_LOCAL

typedef void *(*RzThreadFunction)(void *user);

struct rz_th_t {
	RZ_TH_TID tid;
	RzThreadFunction function;
	void *user;
	void *retv;
	bool breaked;
	bool terminated;
};

#endif

#endif
