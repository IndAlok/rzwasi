/* Emscripten single-threaded stubs for Rizin threading
 * This file provides stub type definitions when building for Emscripten/WASM
 * where real threading is not available.
 */

#ifndef RZ_EMSCRIPTEN_THREAD_STUBS_H
#define RZ_EMSCRIPTEN_THREAD_STUBS_H

#ifdef __EMSCRIPTEN__

/* Thread ID type */
typedef int RZ_TH_TID;

/* Mutex lock type */
typedef int RZ_TH_LOCK_T;

/* Condition variable type */
typedef int RZ_TH_COND_T;

/* Semaphore type */
typedef int RZ_TH_SEM_T;

/* Thread return type */
typedef void* RZ_TH_RET_T;

/* Thread-local storage marker (no-op for single-threaded) */
#define RZ_TH_LOCAL

#endif /* __EMSCRIPTEN__ */

#endif /* RZ_EMSCRIPTEN_THREAD_STUBS_H */
