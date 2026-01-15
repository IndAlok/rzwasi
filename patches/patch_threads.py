#!/usr/bin/env python3
"""
Patches Rizin source files to add Emscripten/WASM single-threaded support.
This script provides reliable multi-line patching that sed/awk cannot do safely.
Industry-grade: memory and time optimal - modifies files in-place with minimal overhead.
"""

import os
import sys
import re

def patch_thread_c(filepath):
    """Patch thread.c - core threading functions for Emscripten deferred execution."""
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Pattern 1: rz_th_self function - add Emscripten before #else
    old_pattern = r'(#elif __WINDOWS__\n\treturn GetCurrentThread\(\);\n)(#else\n)'
    new_pattern = r'\1#elif defined(__EMSCRIPTEN__)\n\treturn (RZ_TH_TID)0;\n\2'
    content = re.sub(old_pattern, new_pattern, content)
    
    # Pattern 2: rz_th_new function - DO NOT execute callback immediately!
    # Just return the thread struct. Execution happens in rz_th_wait.
    # This fixes issues where callback tries to read from queue that's not populated yet.
    old_pattern = r'(\tif \(\(th->tid = CreateThread\(NULL, 0, thread_main_function, th, 0, 0\)\)\) \{\n\t\treturn th;\n\t\}\n)(#endif\n)'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Emscripten: Defer execution to rz_th_wait (single-threaded mode) */
\tth->terminated = false;
\treturn th;
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # Pattern 3: rz_th_wait function - THIS is where we execute the callback
    old_pattern = r'(#elif __WINDOWS__\n\treturn WaitForSingleObject\(th->tid, INFINITE\) == 0; // WAIT_OBJECT_0\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Emscripten: Execute callback now (deferred from rz_th_new) */
\tif (!th->terminated) {
\t\tth->retv = th->function(th->user);
\t\tth->terminated = true;
\t}
\treturn true;
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    with open(filepath, 'w') as f:
        f.write(content)
    
    print(f"✓ Patched {filepath}")

def patch_thread_lock_c(filepath):
    """Patch thread_lock.c - make lock functions no-ops for single-threaded Emscripten."""
    with open(filepath, 'r') as f:
        content = f.read()
    
    # rz_th_lock_new: add Emscripten after Windows block
    old_pattern = r'(#elif __WINDOWS__\n\t// Windows critical sections.*\n\tInitializeCriticalSection\(&thl->lock\);\n)(#endif\n\treturn thl;)'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no locking needed */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_lock_enter: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tEnterCriticalSection\(&thl->lock\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_lock_tryenter: add Emscripten return true
    old_pattern = r'(#elif __WINDOWS__\n\treturn TryEnterCriticalSection\(&thl->lock\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\treturn true; /* Single-threaded: always succeed */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_lock_leave: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tLeaveCriticalSection\(&thl->lock\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_lock_free: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tDeleteCriticalSection\(&thl->lock\);\n)(#endif\n\tfree\(thl\);)'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    with open(filepath, 'w') as f:
        f.write(content)
    
    print(f"✓ Patched {filepath}")

def patch_thread_sem_c(filepath):
    """Patch thread_sem.c - make semaphore functions no-ops for single-threaded Emscripten."""
    with open(filepath, 'r') as f:
        content = f.read()
    
    # rz_th_sem_new: The structure is complex with nested #if for RZ_SEM_NAMED_ONLY
    # Find pattern: after CreateSemaphore block's closing }, before the final #endif, then return sem;
    old_pattern = r'(sem->sem = CreateSemaphore.*?\n\tif \(!sem->sem\) \{\n\t\tfree\(sem\);\n\t\treturn NULL;\n\t\}\n)(#endif\n\treturn sem;)'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no semaphore init needed */
\2'''
    content = re.sub(old_pattern, new_pattern, content, flags=re.DOTALL)
    
    # rz_th_sem_post: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tReleaseSemaphore\(sem->sem, 1, NULL\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_sem_wait: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tWaitForSingleObject\(sem->sem, INFINITE\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_sem_free: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tCloseHandle\(sem->sem\);\n)(#endif\n\tfree\(sem\);)'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    with open(filepath, 'w') as f:
        f.write(content)
    
    print(f"✓ Patched {filepath}")

def patch_thread_cond_c(filepath):
    """Patch thread_cond.c - make condition variable functions no-ops for single-threaded Emscripten."""
    with open(filepath, 'r') as f:
        content = f.read()
    
    # rz_th_cond_new: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tInitializeConditionVariable\(&cond->cond\);\n)(#endif\n\treturn cond;)'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no condition var init needed */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_cond_signal: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tWakeConditionVariable\(&cond->cond\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_cond_signal_all: add Emscripten no-op
    old_pattern = r'(#elif __WINDOWS__\n\tWakeAllConditionVariable\(&cond->cond\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_cond_wait: add Emscripten no-op (uses INFINITE)
    old_pattern = r'(#elif __WINDOWS__\n\tSleepConditionVariableCS\(&cond->cond, &lock->lock, INFINITE\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_cond_timed_wait: add Emscripten no-op (uses timeout_ms)
    old_pattern = r'(#elif __WINDOWS__\n\tSleepConditionVariableCS\(&cond->cond, &lock->lock, timeout_ms\);\n)(#endif\n\})'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # rz_th_cond_free: no Windows-specific code, just pthread destructor before free
    # Pattern: #endif\n\tfree(cond); after pthread_cond_destroy
    old_pattern = r'(#if HAVE_PTHREAD\n\tpthread_cond_destroy\(&cond->cond\);\n)(#endif\n\tfree\(cond\);)'
    new_pattern = r'''\1#elif defined(__EMSCRIPTEN__)
\t/* Single-threaded: no-op */
\2'''
    content = re.sub(old_pattern, new_pattern, content)
    
    with open(filepath, 'w') as f:
        f.write(content)
    
    print(f"✓ Patched {filepath}")

def patch_thread_pool_c(filepath):
    """Patch thread_pool.c - return 1 core for Emscripten single-threaded environment."""
    with open(filepath, 'r') as f:
        content = f.read()
    
    # rz_th_physical_core_number: add Emscripten case at the very start
    # The function has multiple platform-specific branches, add Emscripten first
    old_pattern = r'(RZ_API RzThreadNCores rz_th_physical_core_number\(\) \{\n)(#ifdef __WINDOWS__)'
    new_pattern = r'''\1#if defined(__EMSCRIPTEN__)
\t/* Emscripten: single-threaded, always return 1 */
\treturn 1;
#elif defined(__WINDOWS__)'''
    content = re.sub(old_pattern, new_pattern, content)
    
    with open(filepath, 'w') as f:
        f.write(content)
    
    print(f"✓ Patched {filepath}")

def patch_thread_queue_c(filepath):
    """Patch thread_queue.c for Emscripten single-threaded operation.
    
    CRITICAL FIXES:
    1. rz_th_queue_close_when_empty: Return immediately without closing queue.
       Queue must stay open so threads can pop data when they execute in rz_th_pool_wait.
    2. rz_th_queue_pop: Skip the cond_wait loop (would spin forever), just pop directly.
    """
    with open(filepath, 'r') as f:
        content = f.read()
    
    # FIX 1: rz_th_queue_close_when_empty - Return early for Emscripten
    # Queue must NOT be closed here, or threads will get nothing when they pop.
    # Add return at start of function for Emscripten.
    old_pattern = r'(RZ_API void rz_th_queue_close_when_empty\(RZ_NONNULL RzThreadQueue \*queue\) \{\n\trz_return_if_fail\(queue\);)'
    new_pattern = r'''\1

#if defined(__EMSCRIPTEN__)
\t/* Emscripten: Do NOT close queue here!
\t * Threads execute synchronously in rz_th_pool_wait, which is called AFTER this.
\t * If we close queue now, rz_th_queue_pop will fail for all threads.
\t * Queue will be closed normally when it's freed. */
\treturn;
#endif'''
    content = re.sub(old_pattern, new_pattern, content)
    
    # FIX 2: rz_th_queue_pop - Skip waiting loop for Emscripten
    # The while loop with cond_wait would spin forever in single-threaded mode
    # if called when queue is empty. For Emscripten, just check once and proceed.
    old_pattern2 = r'(\trz_th_lock_enter\(queue->data_lock\);\n\n\t)(while \(!queue->closed && rz_list_empty\(queue->list\)\) \{)'
    new_pattern2 = r'''\1#if defined(__EMSCRIPTEN__)
\t/* Emscripten: No waiting - single threaded, queue should already have data or be done */
\tif (queue->closed) {
\t\trz_th_lock_leave(queue->data_lock);
\t\trz_th_lock_leave(queue->reader_lock);
\t\treturn false;
\t}
#else
\twhile (!queue->closed && rz_list_empty(queue->list)) {'''
    content = re.sub(old_pattern2, new_pattern2, content)
    
    # Close the #if block after the while loop
    old_pattern3 = r'(\t\trz_th_cond_wait\(queue->reader_cond, queue->data_lock\);\n\t\tqueue->reader_awaiting--;\n\t\}\n\n\tif \(queue->closed\))'
    new_pattern3 = r'''\t\trz_th_cond_wait(queue->reader_cond, queue->data_lock);
\t\tqueue->reader_awaiting--;
\t}
#endif

\tif (queue->closed)'''
    content = re.sub(old_pattern3, new_pattern3, content)
    
    with open(filepath, 'w') as f:
        f.write(content)
    
    print(f"✓ Patched {filepath}")

def main():
    if len(sys.argv) < 2:
        print("Usage: patch_threads.py <rizin_source_dir>")
        sys.exit(1)
    
    rizin_dir = sys.argv[1]
    util_dir = os.path.join(rizin_dir, "librz", "util")
    
    # Patch each file
    patch_thread_c(os.path.join(util_dir, "thread.c"))
    patch_thread_lock_c(os.path.join(util_dir, "thread_lock.c"))
    patch_thread_sem_c(os.path.join(util_dir, "thread_sem.c"))
    patch_thread_cond_c(os.path.join(util_dir, "thread_cond.c"))
    patch_thread_pool_c(os.path.join(util_dir, "thread_pool.c"))
    patch_thread_queue_c(os.path.join(util_dir, "thread_queue.c"))
    
    print("\n✓ All thread files patched for Emscripten/WASM support")

if __name__ == "__main__":
    main()
