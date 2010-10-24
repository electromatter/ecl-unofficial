/* -*- mode: c; c-basic-offset: 8 -*- */
/*
    threads.d -- Native threads.
*/
/*
    Copyright (c) 2003, Juan Jose Garcia Ripoll.

    ECL is free software; you can redistribute it and/or
    modify it under the terms of the GNU Library General Public
    License as published by the Free Software Foundation; either
    version 2 of the License, or (at your option) any later version.

    See file '../Copyright' for full details.
*/

#ifndef __sun__ /* See unixinit.d for this */
#define _XOPEN_SOURCE 600	/* For pthread mutex attributes */
#endif
#include <errno.h>
#include <time.h>
#include <signal.h>
#define ECL_INCLUDE_MATH_H
#include <ecl/ecl.h>
#ifdef ECL_WINDOWS_THREADS
# include <windows.h>
#else
# include <pthread.h>
#endif
#ifdef HAVE_GETTIMEOFDAY
# include <sys/time.h>
#endif
#ifdef HAVE_SCHED_YIELD
# include <sched.h>
#endif
#include <ecl/internal.h>
#include <ecl/ecl-inl.h>

#ifdef ECL_WINDOWS_THREADS
/*
 * We have to put this explicit definition here because Boehm GC
 * is designed to produce a DLL and we rather want a static
 * reference
 */
# include <gc.h>
extern HANDLE WINAPI GC_CreateThread(
    LPSECURITY_ATTRIBUTES lpThreadAttributes, 
    DWORD dwStackSize, LPTHREAD_START_ROUTINE lpStartAddress, 
    LPVOID lpParameter, DWORD dwCreationFlags, LPDWORD lpThreadId );
# ifndef WITH___THREAD
DWORD cl_env_key;
# endif
#else
# ifndef WITH___THREAD
static pthread_key_t cl_env_key;
# endif
#endif /* ECL_WINDOWS_THREADS */

extern void ecl_init_env(struct cl_env_struct *env);

#if !defined(WITH___THREAD)
cl_env_ptr
ecl_process_env(void)
{
#ifdef ECL_WINDOWS_THREADS
	return TlsGetValue(cl_env_key);
#else
	struct cl_env_struct *rv = pthread_getspecific(cl_env_key);
        if (rv)
		return rv;
	FElibc_error("pthread_getspecific() failed.", 0);
	return NULL;
#endif
}
#endif

static void
ecl_set_process_env(cl_env_ptr env)
{
#ifdef WITH___THREAD
	cl_env_p = env;
#else
# ifdef ECL_WINDOWS_THREADS
	TlsSetValue(cl_env_key, env);
# else
	if (pthread_setspecific(cl_env_key, env))
		FElibc_error("pthread_setcspecific() failed.", 0);
# endif
#endif
}

cl_object
mp_current_process(void)
{
	return ecl_process_env()->own_process;
}

/*----------------------------------------------------------------------
 * THREAD OBJECT
 */

static void
assert_type_process(cl_object o)
{
	if (type_of(o) != t_process)
		FEwrong_type_argument(@[mp::process], o);
}

static void
thread_cleanup(void *aux)
{
	/* This routine performs some cleanup before a thread is completely
	 * killed. For instance, it has to remove the associated process
	 * object from the list, an it has to dealloc some memory.
	 *
	 * NOTE: thread_cleanup() does not provide enough "protection". In
	 * order to ensure that all UNWIND-PROTECT forms are properly
	 * executed, never use pthread_cancel() to kill a process, but
	 * rather use the lisp functions mp_interrupt_process() and
	 * mp_process_kill().
	 */
	cl_object process = (cl_object)aux;
	cl_env_ptr env = process->process.env;
        process->process.phase = ECL_PROCESS_EXITING;
	process->process.active = 0;
	process->process.env = NULL;
	ECL_WITH_GLOBAL_LOCK_BEGIN(env) {
                cl_core.processes = ecl_remove_eq(process, cl_core.processes);
        } ECL_WITH_GLOBAL_LOCK_END;
        ecl_disable_interrupts_env(env);
	mp_giveup_lock(process->process.exit_lock);
	ecl_set_process_env(NULL);
	if (env) _ecl_dealloc_env(env);
        process->process.phase = ECL_PROCESS_DEAD;
}

#ifdef ECL_WINDOWS_THREADS
static DWORD WINAPI thread_entry_point(void *arg)
#else
static void *
thread_entry_point(void *arg)
#endif
{
        cl_object process = (cl_object)arg;
	cl_env_ptr env = process->process.env;

	/*
	 * Upon entering this routine
	 *	process.env = our environment for lisp
	 *	process.active = 2
	 *	signals are disabled in the environment
	 *
	 * Since process.active = 2, this process will not recevie
	 * signals that originate from other processes. Furthermore,
	 * we expect not to get any other interrupts (SIGSEGV, SIGFPE)
	 * if we do things right.
	 */
	/* 1) Setup the environment for the execution of the thread */
        process->process.phase = ECL_PROCESS_BOOTING;
	ecl_set_process_env(env = process->process.env);
#ifndef ECL_WINDOWS_THREADS
	pthread_cleanup_push(thread_cleanup, (void *)process);
#endif
	ecl_cs_set_org(env);
        si_trap_fpe(@'last', Ct);
        ECL_WITH_GLOBAL_LOCK_BEGIN(env) {
                cl_core.processes = CONS(process, cl_core.processes);
        } ECL_WITH_GLOBAL_LOCK_END;
	ecl_enable_interrupts_env(env);

	/* 2) Execute the code. The CATCH_ALL point is the destination
	*     provides us with an elegant way to exit the thread: we just
	*     do an unwind up to frs_top.
	*/
	mp_get_lock_wait(process->process.exit_lock);
	process->process.active = 1;
        process->process.phase = ECL_PROCESS_ACTIVE;
	CL_CATCH_ALL_BEGIN(env) {
		ecl_bds_bind(env, @'mp::*current-process*', process);
		env->values[0] = cl_apply(2, process->process.function,
                                          process->process.args);
                {
                        cl_object output = Cnil;
                        int i = env->nvalues;
                        while (i--) {
                                output = CONS(env->values[i], output);
                        }
                        process->process.exit_values = output;
                }
		ecl_bds_unwind1(env);
	} CL_CATCH_ALL_END;

	/* 4) If everything went right, we should be exiting the thread
	 *    through this point. thread_cleanup is automatically invoked
	 *    marking the process as inactive.
	 */
        process->process.phase = ECL_PROCESS_EXITING;
#ifdef ECL_WINDOWS_THREADS
	thread_cleanup(process);
	return 1;
#else
	pthread_cleanup_pop(1);
	return NULL;
#endif
}

static cl_object
alloc_process(cl_object name, cl_object initial_bindings)
{
	cl_object process = ecl_alloc_object(t_process), array;
        process->process.phase = ECL_PROCESS_INACTIVE;
	process->process.active = 0;
	process->process.name = name;
	process->process.function = Cnil;
	process->process.args = Cnil;
	process->process.interrupt = Cnil;
        process->process.exit_values = Cnil;
	process->process.env = NULL;
	if (initial_bindings != OBJNULL) {
		array = si_make_vector(Ct, MAKE_FIXNUM(256),
                                       Cnil, Cnil, Cnil, Cnil);
                si_fill_array_with_elt(array, OBJNULL, MAKE_FIXNUM(0), Cnil);
	} else {
		array = cl_copy_seq(ecl_process_env()->bindings_array);
	}
        process->process.initial_bindings = array;
	process->process.exit_lock = mp_make_lock(0);
	return process;
}

bool
ecl_import_current_thread(cl_object name, cl_object bindings)
{
	cl_object process, l;
	pthread_t current;
	cl_env_ptr env;
#ifdef ECL_WINDOWS_THREADS
	{
	HANDLE aux = GetCurrentThread();
	DuplicateHandle(GetCurrentProcess(),
			aux,
			GetCurrentProcess(),
			&current,
			0,
			FALSE,
			DUPLICATE_SAME_ACCESS);
	CloseHandle(current);
	}
#else
	current = pthread_self();
#endif
#ifdef GBC_BOEHM
	GC_register_my_thread((void*)&name);
#endif
	for (l = cl_core.processes; l != Cnil; l = ECL_CONS_CDR(l)) {
		cl_object p = ECL_CONS_CAR(l);
		if (p->process.thread == current) {
			return 0;
		}
	}
	env = _ecl_alloc_env();
	ecl_set_process_env(env);
	env->own_process = process = alloc_process(name, bindings);
        process->process.phase = ECL_PROCESS_BOOTING;
	process->process.active = 2;
	process->process.thread = current;
	process->process.env = env;
	ecl_init_env(env);
	env->bindings_array = process->process.initial_bindings;
        env->thread_local_bindings_size = env->bindings_array->vector.dim;
        env->thread_local_bindings = env->bindings_array->vector.self.t;
	ECL_WITH_GLOBAL_LOCK_BEGIN(env) {
                cl_core.processes = CONS(process, cl_core.processes);
        } ECL_WITH_GLOBAL_LOCK_END;
	ecl_enable_interrupts_env(env);
	mp_get_lock_wait(process->process.exit_lock);
	process->process.active = 1;
        process->process.phase = ECL_PROCESS_ACTIVE;
	return 1;
}

void
ecl_release_current_thread(void)
{
	thread_cleanup(ecl_process_env()->own_process);
#ifdef GBC_BOEHM
	GC_unregister_my_thread();
#endif
}

@(defun mp::make-process (&key name ((:initial-bindings initial_bindings) Ct))
	cl_object process;
@
	process = alloc_process(name, initial_bindings);
	@(return process)
@)

cl_object
mp_process_preset(cl_narg narg, cl_object process, cl_object function, ...)
{
	cl_va_list args;
	cl_va_start(args, function, narg, 2);
	if (narg < 2)
		FEwrong_num_arguments(@[mp::process-preset]);
	assert_type_process(process);
	process->process.function = function;
	process->process.args = cl_grab_rest_args(args);
	@(return process)
}

cl_object
mp_interrupt_process(cl_object process, cl_object function)
{
	if (mp_process_active_p(process) == Cnil)
		FEerror("Cannot interrupt the inactive process ~A", 1, process);
        ecl_interrupt_process(process, function);
	@(return Ct)
}

cl_object
mp_suspend_loop()
{
        cl_env_ptr env = ecl_process_env();
        CL_CATCH_BEGIN(env,@'mp::suspend-loop') {
                for ( ; ; ) {
                        cl_sleep(MAKE_FIXNUM(100));
                }
        } CL_CATCH_END;
}

cl_object
mp_break_suspend_loop()
{
        if (frs_sch(@'mp::suspend-loop')) {
                cl_throw(@'mp::suspend-loop');
        }
}

cl_object
mp_process_suspend(cl_object process)
{
        mp_interrupt_process(process, @'mp::suspend-loop');
}

cl_object
mp_process_resume(cl_object process)
{
        mp_interrupt_process(process, @'mp::break-suspend-loop');
}

cl_object
mp_process_kill(cl_object process)
{
	return mp_interrupt_process(process, @'mp::exit-process');
}

cl_object
mp_process_yield(void)
{
#ifdef HAVE_SCHED_YIELD
	sched_yield();
#else
# ifdef ECL_WINDOWS_THREADS
	Sleep(0);
# else
	sleep(0); /* Use sleep(0) to yield to a >= priority thread */
# endif
#endif
	@(return)
}

cl_object
mp_process_enable(cl_object process)
{
	/*
	 * We try to grab the process exit lock. If we achieve it that
	 * means the 1) process is not running or in the finalization
	 * or 2) it is in the initialization phase. The second case we
	 * can distinguish because process.active != 0. The first one
	 * is ok.
	 */
	cl_env_ptr process_env;
	int ok;
	if (Null(mp_get_lock_nowait(process->process.exit_lock))) {
		FEerror("Cannot enable the running process ~A.", 1, process);
		return;
	}
	if (process->process.active) {
		mp_giveup_lock(process->process.exit_lock);
		FEerror("Cannot enable the running process ~A.", 1, process);
		return;
	}
	process_env = _ecl_alloc_env();
	ecl_init_env(process_env);
	process_env->trap_fpe_bits = process->process.trap_fpe_bits;
	process_env->bindings_array = process->process.initial_bindings;
        process_env->thread_local_bindings_size = 
                process_env->bindings_array->vector.dim;
        process_env->thread_local_bindings =
                process_env->bindings_array->vector.self.t;
	process_env->own_process = process;

	process->process.env = process_env;
        process->process.parent = mp_current_process();
	process->process.trap_fpe_bits =
		process->process.parent->process.env->trap_fpe_bits;
	process->process.active = 2;

#ifdef ECL_WINDOWS_THREADS
	{
	HANDLE code;
	DWORD threadId;

	code = (HANDLE)CreateThread(NULL, 0, thread_entry_point, process, 0, &threadId);
	ok = (process->process.thread = code) != NULL;
	}
#else
	{
	int code;
        pthread_attr_t pthreadattr;

	pthread_attr_init(&pthreadattr);
	pthread_attr_setdetachstate(&pthreadattr, PTHREAD_CREATE_DETACHED);
	/*
	 * We launch the thread with the signal mask specified in cl_core.
	 * The reason is that we might need to block certain signals
	 * to be processed by the signal handling thread in unixint.d
	 */
#ifdef HAVE_SIGPROCMASK
	{
		sigset_t previous;
		pthread_sigmask(SIG_SETMASK, cl_core.default_sigmask, &previous);
		code = pthread_create(&process->process.thread, &pthreadattr,
				      thread_entry_point, process);
		pthread_sigmask(SIG_SETMASK, &previous, NULL);
	}
#else
	code = pthread_create(&process->process.thread, &pthreadattr,
			      thread_entry_point, process);
#endif
	ok = (code == 0);
	}
#endif
	if (!ok) {
		process->process.active = 0;
		process->process.env = NULL;
		_ecl_dealloc_env(process_env);
	}
	mp_giveup_lock(process->process.exit_lock);

	@(return (ok? process : Cnil))
}

cl_object
mp_exit_process(void)
{
	/* We simply undo the whole of the frame stack. This brings up
	   back to the thread entry point, going through all possible
	   UNWIND-PROTECT.
	*/
	const cl_env_ptr env = ecl_process_env();
	ecl_unwind(env, env->frs_org);
}

cl_object
mp_all_processes(void)
{
	/* No race condition here because this list is never destructively
	 * modified. When we add or remove processes, we create new lists. */
	@(return cl_copy_list(cl_core.processes))
}

cl_object
mp_process_name(cl_object process)
{
	assert_type_process(process);
	@(return process->process.name)
}

cl_object
mp_process_active_p(cl_object process)
{
	assert_type_process(process);
	@(return (process->process.active? Ct : Cnil))
}

cl_object
mp_process_whostate(cl_object process)
{
	assert_type_process(process);
	@(return (cl_core.null_string))
}

cl_object
mp_process_join(cl_object process)
{
	assert_type_process(process);
	/* We only wait for threads that we have created */
        if (process->process.active) {
		cl_object l = process->process.exit_lock;
		if (!Null(l)) {
                        while (process->process.active > 1)
                                cl_sleep(MAKE_FIXNUM(0));
			l = mp_get_lock_wait(l);
			if (Null(l)) {
				FEerror("MP:PROCESS-JOIN: Error when "
					"joining process ~A",
					1, process);
			}
			mp_giveup_lock(l);
                }
        }
        return cl_values_list(process->process.exit_values);
}

cl_object
mp_process_run_function(cl_narg narg, cl_object name, cl_object function, ...)
{
	cl_object process;
	cl_va_list args;
	cl_va_start(args, function, narg, 2);
	if (narg < 2)
		FEwrong_num_arguments(@[mp::process-run-function]);
	if (CONSP(name)) {
		process = cl_apply(2, @'mp::make-process', name);
	} else {
		process = mp_make_process(2, @':name', name);
	}
	cl_apply(4, @'mp::process-preset', process, function,
		 cl_grab_rest_args(args));
	return mp_process_enable(process);
}

cl_object
mp_process_run_function_wait(cl_narg narg, ...)
{
	cl_object process;
	cl_va_list args;
	cl_va_start(args, narg, narg, 0);
	process = cl_apply(2, @'mp::process-run-function',
                           cl_grab_rest_args(args));
        if (!Null(process)) {
                ecl_def_ct_single_float(wait, 0.001, static, const);
                while (process->process.phase < ECL_PROCESS_ACTIVE) {
                        cl_sleep(wait);
                }
        }
	@(return process)
}

/*----------------------------------------------------------------------
 * INTERRUPTS
 */

#ifndef ECL_WINDOWS_THREADS
static cl_object
mp_get_sigmask(void)
{
        cl_object data = ecl_alloc_simple_vector(sizeof(sigset_t), aet_b8);
        sigset_t *mask_ptr = (sigset_t*)data->vector.self.b8;
        sigset_t no_signals;
        sigemptyset(&no_signals);
        if (pthread_sigmask(SIG_BLOCK, &no_signals, mask_ptr))
                FElibc_error("MP:GET-SIGMASK failed in a call to pthread_sigmask", 0);
        @(return data)
}

static cl_object
mp_set_sigmask(cl_object data)
{
        sigset_t *mask_ptr = (sigset_t*)data->vector.self.b8;
        if (pthread_sigmask(SIG_SETMASK, mask_ptr, NULL))
                FElibc_error("MP:SET-SIGMASK failed in a call to pthread_sigmask", 0);
        @(return data)
}
#endif

cl_object
mp_block_signals(void)
{
#ifdef ECL_WINDOWS_THREADS
        cl_env_ptr the_env = ecl_process_env();
        cl_object previous = ecl_symbol_value(@'si::*interrupts-enabled*');
        ECL_SETQ(the_env, @'si::*interrupts-enabled*', Cnil);
        @(return previous)
#else
        cl_object previous = mp_get_sigmask();
        sigset_t all_signals;
        sigfillset(&all_signals);
        if (pthread_sigmask(SIG_SETMASK, &all_signals, NULL))
                FElibc_error("MP:BLOCK-SIGNALS failed in a call to pthread_sigmask",0);
        @(return previous)
#endif
}

cl_object
mp_restore_signals(cl_object sigmask)
{
#ifdef ECL_WINDOWS_THREADS
        cl_env_ptr the_env = ecl_process_env();
        ECL_SETQ(the_env, @'si::*interrupts-enabled*', sigmask);
        ecl_check_pending_interrupts();
        @(return sigmask)
#else
        return mp_set_sigmask(sigmask);
#endif
}

/*----------------------------------------------------------------------
 * INITIALIZATION
 */

void
init_threads(cl_env_ptr env)
{
	cl_object process;
	pthread_t main_thread;

	cl_core.processes = OBJNULL;

	/* We have to set the environment before any allocation takes place,
	 * so that the interrupt handling code works. */
#if !defined(WITH___THREAD)
# if defined(ECL_WINDOWS_THREADS)
	cl_env_key = TlsAlloc();
# else
	pthread_key_create(&cl_env_key, NULL);
# endif
#endif
	ecl_set_process_env(env);

#ifdef ECL_WINDOWS_THREADS
	{
	HANDLE aux = GetCurrentThread();
	DuplicateHandle(GetCurrentProcess(),
			aux,
			GetCurrentProcess(),
			&main_thread,
			0,
			FALSE,
			DUPLICATE_SAME_ACCESS);
	}
#else
	main_thread = pthread_self();
#endif
	process = ecl_alloc_object(t_process);
	process->process.active = 1;
	process->process.name = @'si::top-level';
	process->process.function = Cnil;
	process->process.args = Cnil;
	process->process.thread = main_thread;
	process->process.env = env;

	env->own_process = process;

        cl_core.global_lock = ecl_make_lock(@'mp::global-lock', 1);
        cl_core.error_lock = ecl_make_lock(@'mp::error-lock', 1);
        cl_core.package_lock = ecl_make_rwlock(@'mp::package-lock');
	cl_core.processes = ecl_list1(process);
}