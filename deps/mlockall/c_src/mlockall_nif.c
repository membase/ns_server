/**
 * @author Couchbase <info@couchbase.com>
 * @copyright 2012 Couchbase, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
**/

#include <errno.h>
#include <string.h>
#include <stdbool.h>
#include <sys/mman.h>
#include <sys/types.h>

#include "erl_driver.h"
#include "erl_nif_compat.h"

static bool parse_flags(ErlNifEnv *env, ERL_NIF_TERM erl_flags, int *pflags);
static ERL_NIF_TERM make_errno_error(ErlNifEnv *env, int errnum);

ERL_NIF_TERM
lock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  int flags;

  if (!parse_flags(env, argv[0], &flags)) {
    return enif_make_badarg(env);
  }

  if (mlockall(flags) != 0) {
    return make_errno_error(env, errno);
  }

  return enif_make_atom(env, "ok");
}

ERL_NIF_TERM
unlock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
  if (munlockall() != 0) {
    return make_errno_error(env, errno);
  }

  return enif_make_atom(env, "ok");
}

static bool
parse_flags(ErlNifEnv *env, ERL_NIF_TERM erl_flags, int *pflags)
{
  int flags = 0;
  ERL_NIF_TERM tail;
  ERL_NIF_TERM head;

  if (!enif_is_list(env, erl_flags)) {
    return false;
  }

  tail = erl_flags;

  while (enif_get_list_cell(env, tail, &head, &tail)) {
    char atom[10];

    if (!enif_get_atom_compat(env, head, atom, sizeof(atom))) {
      return false;
    }

    if (strcmp(atom, "future") == 0) {
      flags |= MCL_FUTURE;
    } else if (strcmp(atom, "current") == 0) {
      flags |= MCL_CURRENT;
    } else {
      return false;
    }
  }

  if (!flags) {
    return false;
  }

  *pflags = flags;

  return true;
}

static ERL_NIF_TERM
make_errno_error(ErlNifEnv *env, int errnum)
{
  return enif_make_tuple2(env,
                          enif_make_atom(env, "error"),
                          enif_make_atom(env, erl_errno_id(errnum)));
}

static ErlNifFunc nif_functions[] = {
    {"lock", 1, lock},
    {"unlock", 0, unlock},
};

ERL_NIF_INIT(mlockall, nif_functions, NULL, NULL, NULL, NULL);
