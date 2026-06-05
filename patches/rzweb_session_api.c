#include <rz_cmd.h>
#include <rz_cons.h>
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

// Optional
#ifdef RZWEB_ENABLE_JSDEC
extern RzCorePlugin rz_core_plugin_jsdec;
#endif

#define RZWEB_MAX_SESSIONS 8

typedef struct rzweb_session_t {
	RzCore *core;
	char *last_output;
	char *last_error;
	char *last_completion;
	char *last_command_catalog;
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
#ifdef RZWEB_ENABLE_JSDEC
	// Register the statically linked jsdec plugin so `pdd` is available on every
	// fresh core. Failure is non-fatal: the session still works without it.
	rz_core_plugin_add(session->core, &rz_core_plugin_jsdec);
#endif
	rzweb_apply_defaults(session->core);
	rzweb_clear_error(session);
	return true;
}

static const char *rzweb_empty_completion_json(RzwebSession *session) {
	const char *payload = "{\"start\":0,\"end\":0,\"endString\":\"\",\"options\":[]}";
	if (!session) {
		return payload;
	}
	rzweb_set_string(&session->last_completion, payload);
	return session->last_completion ? session->last_completion : payload;
}

static void rzweb_fill_line_buffer(RzLineBuffer *buf, const char *input, int cursor_pos) {
	memset(buf, 0, sizeof(*buf));
	if (!input) {
		return;
	}

	size_t input_len = strlen(input);
	if (input_len >= RZ_LINE_BUFSIZE) {
		input_len = RZ_LINE_BUFSIZE - 1;
	}

	memcpy(buf->data, input, input_len);
	buf->data[input_len] = '\0';
	buf->length = (int)input_len;

	if (cursor_pos < 0) {
		cursor_pos = 0;
	} else if (cursor_pos > buf->length) {
		cursor_pos = buf->length;
	}
	buf->index = cursor_pos;
}

static bool rzweb_add_command_catalog_entry(RzCmd *cmd, const RzCmdDesc *desc, void *user) {
	PJ *j = (PJ *)user;
	if (!cmd || !desc || !desc->name || !*desc->name || !j) {
		return true;
	}

	const RzCmdDescHelp *help = desc->help;
	pj_ko(j, desc->name);
	pj_ks(j, "name", desc->name);
	pj_ks(j, "summary", help ? rz_str_get(help->summary) : "");
	pj_ks(j, "description", help ? rz_str_get(help->description) : "");
	pj_ks(j, "args", help ? rz_str_get(help->args_str) : "");
	pj_end(j);
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
		rzweb_set_string(&session->last_completion, "");
		rzweb_set_string(&session->last_command_catalog, "");

		if (!rzweb_reset_core(session)) {
			free(session->last_output);
			free(session->last_error);
			free(session->last_completion);
			free(session->last_command_catalog);
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
	free(session->last_completion);
	free(session->last_command_catalog);
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

EMSCRIPTEN_KEEPALIVE const char *rzweb_autocomplete(int session_id, const char *input, int cursor_pos, int max_results) {
	RzwebSession *session = rzweb_get_session(session_id);
	if (!session || !session->core) {
		return "{\"start\":0,\"end\":0,\"endString\":\"\",\"options\":[]}";
	}
	if (!input || cursor_pos <= 0) {
		return rzweb_empty_completion_json(session);
	}

	if (max_results <= 0) {
		max_results = 12;
	}

	RzLineBuffer buf;
	rzweb_fill_line_buffer(&buf, input, cursor_pos);

	RzLineNSCompletionResult *res = rz_core_autocomplete_rzshell(session->core, &buf, RZ_LINE_PROMPT_DEFAULT);
	PJ *j = pj_new();
	if (!j) {
		if (res) {
			rz_line_ns_completion_result_free(res);
		}
		return rzweb_empty_completion_json(session);
	}

	pj_o(j);
	pj_ki(j, "start", res ? (int)res->start : 0);
	pj_ki(j, "end", res ? (int)res->end : 0);
	pj_ks(j, "endString", res && res->end_string ? res->end_string : "");
	pj_ka(j, "options");
	if (res) {
		size_t count = rz_pvector_len(&res->options);
		if (count > (size_t)max_results) {
			count = (size_t)max_results;
		}
		for (size_t i = 0; i < count; i++) {
			const char *option = (const char *)rz_pvector_at(&res->options, i);
			if (option && *option) {
				pj_s(j, option);
			}
		}
	}
	pj_end(j);
	pj_end(j);

	char *json = pj_drain(j);
	if (res) {
		rz_line_ns_completion_result_free(res);
	}
	if (!json) {
		return rzweb_empty_completion_json(session);
	}

	rzweb_set_string(&session->last_completion, json);
	free(json);
	return session->last_completion ? session->last_completion : "";
}

EMSCRIPTEN_KEEPALIVE const char *rzweb_get_command_catalog(int session_id) {
	RzwebSession *session = rzweb_get_session(session_id);
	if (!session || !session->core || !session->core->rcmd) {
		return "{}";
	}

	PJ *j = pj_new();
	if (!j) {
		rzweb_set_string(&session->last_command_catalog, "{}");
		return session->last_command_catalog ? session->last_command_catalog : "{}";
	}

	pj_o(j);
	rz_cmd_foreach_cmdname(session->core->rcmd, NULL, rzweb_add_command_catalog_entry, j);
	pj_end(j);

	char *json = pj_drain(j);
	if (!json) {
		rzweb_set_string(&session->last_command_catalog, "{}");
		return session->last_command_catalog ? session->last_command_catalog : "{}";
	}

	rzweb_set_string(&session->last_command_catalog, json);
	free(json);
	return session->last_command_catalog ? session->last_command_catalog : "";
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
