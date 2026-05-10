#include "internal.h"

#include <stdlib.h>
#include <string.h>

char *mg_strdup(const char *value) {
    if (!value) {
        return NULL;
    }

    size_t length = strlen(value);
    char *copy = (char *)malloc(length + 1);
    if (!copy) {
        return NULL;
    }

    memcpy(copy, value, length + 1);
    return copy;
}

void mg_clear_error(mg_error_t **out_error) {
    if (out_error) {
        *out_error = NULL;
    }
}

mg_status_t mg_set_error(mg_error_t **out_error, mg_status_t status, mg_error_stage_t stage,
                         mg_node_id_t node_id, const char *message, const char *backend_message) {
    if (!out_error) {
        return status;
    }

    *out_error = NULL;
    mg_error_t *error = (mg_error_t *)calloc(1, sizeof(*error));
    if (!error) {
        return status;
    }

    error->status = status;
    error->stage = stage;
    error->node_id = node_id;
    error->message = mg_strdup(message ? message : mg_status_string(status));
    error->backend_message = mg_strdup(backend_message);

    if (!error->message || (backend_message && !error->backend_message)) {
        mg_error_destroy(error);
        return status;
    }

    *out_error = error;
    return status;
}

mg_status_t mg_set_oom(mg_error_t **out_error, mg_error_stage_t stage) {
    return mg_set_error(out_error, MG_STATUS_OUT_OF_MEMORY, stage, MG_NODE_ID_INVALID,
                        "out of memory", NULL);
}

void mg_error_destroy(mg_error_t *error) {
    if (!error) {
        return;
    }

    free(error->message);
    free(error->backend_message);
    free(error);
}

mg_status_t mg_error_status(const mg_error_t *error) {
    return error ? error->status : MG_STATUS_OK;
}

mg_error_stage_t mg_error_stage(const mg_error_t *error) {
    return error ? error->stage : MG_ERROR_STAGE_NONE;
}

mg_node_id_t mg_error_node_id(const mg_error_t *error) {
    return error ? error->node_id : MG_NODE_ID_INVALID;
}

const char *mg_error_message(const mg_error_t *error) { return error ? error->message : ""; }

const char *mg_error_backend_message(const mg_error_t *error) {
    return error && error->backend_message ? error->backend_message : "";
}
