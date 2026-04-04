#include <rz_core.h>
#include <rz_project.h>
#include <rz_types.h>
#include <rz_util.h>

#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#else
#define EMSCRIPTEN_KEEPALIVE
#endif

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define RZWEB_MAX_SESSIONS 8

typedef struct rzweb_session_t {
	RzCore *core;
	char *last_output;
	char *last_error;
	bool in_use;
} RzwebSession;

static RzwebSession rzweb_sessions[RZWEB_MAX_SESSIONS];

static void rzweb_set_string(char **slot, const char *value) {
	free(*slot);
	*slot = rz_str_dup(value ? value : "");
}

static RzwebSession *rzweb_get_session(int session_id) {
	if (session_id <= 0 || session_id > RZWEB_MAX_SESSIONS) {
		return NULL;
	}
	RzwebSession *session = &rzweb_sessions[session_id - 1];
	return session->in_use ? session : NULL;
}

static int rzweb_fail(RzwebSession *session, const char *message) {
	if (session) {
		rzweb_set_string(&session->last_error, message);
	}
	return 0;
}

static void rzweb_clear_error(RzwebSession *session) {
	if (session) {
		rzweb_set_string(&session->last_error, "");
	}
}

static void rzweb_apply_defaults(RzCore *core) {
	char *result = rz_core_cmd_str(core,
		"e scr.color=0;"
		"e scr.interactive=false;"
		"e scr.prompt=false;"
		"e scr.utf8=false;"
		"e scr.utf8.curvy=false;"
		"e log.level=0;"
		"e scr.pager=");
	free(result);
}

static bool rzweb_reset_core(RzwebSession *session) {
	if (!session) {
		return false;
	}
	if (session->core) {
		rz_core_free(session->core);
		session->core = NULL;
	}
	session->core = rz_core_new();
	if (!session->core) {
		rzweb_set_string(&session->last_error, "Failed to allocate Rizin core");
		return false;
	}
	rzweb_apply_defaults(session->core);
	rzweb_clear_error(session);
	return true;
}

EMSCRIPTEN_KEEPALIVE int rzweb_create_session(void) {
	for (int i = 0; i < RZWEB_MAX_SESSIONS; i++) {
		RzwebSession *session = &rzweb_sessions[i];
		if (session->in_use) {
			continue;
		}

		memset(session, 0, sizeof(*session));
		session->in_use = true;
		rzweb_set_string(&session->last_output, "");
		rzweb_set_string(&session->last_error, "");

		if (!rzweb_reset_core(session)) {
			free(session->last_output);
			free(session->last_error);
			memset(session, 0, sizeof(*session));
			return 0;
		}

		return i + 1;
	}

	return 0;
}

EMSCRIPTEN_KEEPALIVE int rzweb_close_session(int session_id) {
	RzwebSession *session = rzweb_get_session(session_id);
	if (!session) {
		return 0;
	}

	if (session->core) {
		rz_core_free(session->core);
	}
	free(session->last_output);
	free(session->last_error);
	memset(session, 0, sizeof(*session));
	return 1;
}

EMSCRIPTEN_KEEPALIVE const char *rzweb_get_last_error(int session_id) {
	RzwebSession *session = rzweb_get_session(session_id);
	return session && session->last_error ? session->last_error : "";
}

EMSCRIPTEN_KEEPALIVE int rzweb_open_file(int session_id, const char *file_path, int write_mode, int io_cache) {
	RzwebSession *session = rzweb_get_session(session_id);
	if (!session || !file_path || !*file_path) {
		return 0;
	}
	if (!rzweb_reset_core(session)) {
		return 0;
	}

	char *io_cache_result = rz_core_cmd_str(session->core, io_cache ? "e io.cache=true" : "e io.cache=false");
	free(io_cache_result);

	const int perms = write_mode ? RZ_PERM_RW : RZ_PERM_R;
	if (!rz_core_file_open_load(session->core, file_path, 0, perms, write_mode != 0)) {
		return rzweb_fail(session, "Failed to open and load binary");
	}

	rzweb_clear_error(session);
	return 1;
}

EMSCRIPTEN_KEEPALIVE const char *rzweb_cmd(int session_id, const char *command) {
	RzwebSession *session = rzweb_get_session(session_id);
	if (!session || !session->core) {
		return "";
	}

	char *result = rz_core_cmd_str(session->core, command ? command : "");
	rzweb_set_string(&session->last_output, result ? result : "");
	free(result);
	rzweb_clear_error(session);
	return session->last_output ? session->last_output : "";
}

EMSCRIPTEN_KEEPALIVE const char *rzweb_get_seek(int session_id) {
	return rzweb_cmd(session_id, "s");
}

EMSCRIPTEN_KEEPALIVE int rzweb_save_project(int session_id, const char *project_path, int compress) {
	RzwebSession *session = rzweb_get_session(session_id);
	if (!session || !session->core || !project_path || !*project_path) {
		return 0;
	}

	RzProjectErr err = rz_project_save_file(session->core, project_path, compress != 0);
	if (err != RZ_PROJECT_ERR_SUCCESS) {
		return rzweb_fail(session, rz_project_err_message(err));
	}

	rzweb_clear_error(session);
	return 1;
}

EMSCRIPTEN_KEEPALIVE int rzweb_load_project(int session_id, const char *project_path, int load_bin_io) {
	RzwebSession *session = rzweb_get_session(session_id);
	if (!session || !project_path || !*project_path) {
		return 0;
	}
	if (!rzweb_reset_core(session)) {
		return 0;
	}

	RzSerializeResultInfo result_info = { 0 };
	RzProjectErr err = rz_project_load_file(session->core, project_path, load_bin_io != 0, &result_info);
	if (err != RZ_PROJECT_ERR_SUCCESS) {
		return rzweb_fail(session, rz_project_err_message(err));
	}

	rzweb_clear_error(session);
	return 1;
}
