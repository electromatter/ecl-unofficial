/* -*- mode: c; c-basic-offset: 8 -*- */
/*
    mutex.d -- mutually exclusive locks.
*/
/*
    Copyright (c) 2003, Juan Jose Garcia Ripoll.

    ECL is free software; you can redistribute it and/or
    modify it under the terms of the GNU Library General Public
    License as published by the Free Software Foundation; either
    version 2 of the License, or (at your option) any later version.

    See file '../Copyright' for full details.
*/

#define AO_ASSUME_WINDOWS98 /* We need this for CAS */
#include <ecl/ecl.h>
#include <ecl/internal.h>

/*----------------------------------------------------------------------
 * LOCKS or MUTEX
 */

static void
FEerror_not_a_lock(cl_object lock)
{
        FEwrong_type_argument(@'mp::lock', lock);
}

static void
FEerror_not_a_recursive_lock(cl_object lock)
{
        FEerror("Attempted to recursively lock ~S which is already owned by ~S",
                2, lock, lock->lock.owner);
}

static void
FEerror_not_owned(cl_object lock)
{
        FEerror("Attempted to give up lock ~S that is not owned by process ~S",
                2, lock, mp_current_process());
}

cl_object
ecl_make_lock(cl_object name, bool recursive)
{
	cl_object output = ecl_alloc_object(t_lock);
	output->lock.name = name;
	output->lock.owner = Cnil;
	output->lock.counter = 0;
	output->lock.waiter = Cnil;
	output->lock.recursive = recursive;
        return output;
}

@(defun mp::make-lock (&key name ((:recursive recursive) Ct))
@
	@(return ecl_make_lock(name, !Null(recursive)))
@)

cl_object
mp_recursive_lock_p(cl_object lock)
{
	cl_env_ptr env = ecl_process_env();
	unlikely_if (type_of(lock) != t_lock)
		FEerror_not_a_lock(lock);
	ecl_return1(env, lock->lock.recursive? Ct : Cnil);
}

cl_object
mp_lock_name(cl_object lock)
{
	cl_env_ptr env = ecl_process_env();
	unlikely_if (type_of(lock) != t_lock) {
		FEerror_not_a_lock(lock);
	}
        ecl_return1(env, lock->lock.name);
}

cl_object
mp_lock_owner(cl_object lock)
{
	cl_env_ptr env = ecl_process_env();
	unlikely_if (type_of(lock) != t_lock) {
		FEerror_not_a_lock(lock);
	}
        ecl_return1(env, lock->lock.owner);
}

cl_object
mp_lock_count(cl_object lock)
{
	cl_env_ptr env = ecl_process_env();
	unlikely_if (type_of(lock) != t_lock) {
		FEerror_not_a_lock(lock);
	}
	ecl_return1(env, MAKE_FIXNUM(lock->lock.counter));
}

cl_object
mp_giveup_lock(cl_object lock)
{
        /* Must be called with interrupts disabled. */
        cl_env_ptr env = ecl_process_env();
	cl_object own_process = env->own_process;
	unlikely_if (type_of(lock) != t_lock) {
		FEerror_not_a_lock(lock);
	}
	unlikely_if (lock->lock.owner != own_process) {
                FEerror_not_owned(lock);
	}
	ecl_disable_interrupts_env(env);
	if (--lock->lock.counter == 0) {
		lock->lock.owner = Cnil;
		if (lock->lock.waiter != Cnil) {
			lock->lock.waiter = Cnil;
			ecl_wakeup_waiters(lock, ECL_WAKEUP_ONE);
		}
	}
	ecl_enable_interrupts_env(env);
        ecl_return1(env, Ct);
}

static cl_fixnum
get_lock_inner(cl_object lock, cl_object own_process)
{
        if (AO_compare_and_swap_full((AO_t*)&(lock->lock.owner),
				     (AO_t)Cnil, (AO_t)own_process)) {
		return lock->lock.counter = 1;
	} else if (lock->lock.owner == own_process) {
                if (!lock->lock.recursive) {
			return -1;
		}
                return ++lock->lock.counter;
        } else {
		return 0;
	}
}

cl_object
mp_get_lock_nowait(cl_object lock)
{
        cl_env_ptr env = ecl_process_env();
	cl_object own_process = env->own_process;
	cl_fixnum code;
	unlikely_if (type_of(lock) != t_lock) {
		FEerror_not_a_lock(lock);
	}
	ecl_disable_interrupts_env(env);
	code = get_lock_inner(lock, own_process);
	ecl_enable_interrupts_env(env);
	unlikely_if (code < 0)
		FEerror_not_a_recursive_lock(lock);
	ecl_return1(env, code? Ct : Cnil);
}

cl_object
mp_get_lock_wait(cl_object lock)
{
	if (mp_get_lock_nowait(lock) == Cnil) {
		ecl_wait_on(mp_get_lock_nowait, lock);
	}
	@(return Ct)
}

@(defun mp::get-lock (lock &optional (wait Ct))
@
	if (Null(wait))
        	return mp_get_lock_nowait(lock);
        else
        	return mp_get_lock_wait(lock);
@)
