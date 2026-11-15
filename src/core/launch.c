#include "internal.h"

#include <stddef.h>
#include <string.h>

mg_status_t mgLaunchGetDiagnostics(const mg_launch_t *launch,
                                   mg_launch_diagnostics_t *out_diagnostics,
                                   mg_error_t **out_error) {
    mg_clear_error(out_error);
    size_t caller_size = out_diagnostics ? out_diagnostics->size : 0;
    if (!launch || !out_diagnostics ||
        caller_size < offsetof(mg_launch_diagnostics_t, completed)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_SYNC,
                            MG_NODE_ID_INVALID, "launch and diagnostics output are required",
                            NULL);
    }

    memset(out_diagnostics, 0,
           caller_size < sizeof(*out_diagnostics) ? caller_size : sizeof(*out_diagnostics));
    out_diagnostics->size = sizeof(*out_diagnostics);
    out_diagnostics->sync_mode_flags = launch->sync_mode_flags;
    out_diagnostics->synchronize_count = launch->synchronize_count;
    out_diagnostics->event_wait_count = launch->event_wait_count;
    out_diagnostics->event_signal_count = launch->event_signal_count;
    if (caller_size >= sizeof(*out_diagnostics)) {
        out_diagnostics->completed = launch->completed ? 1u : 0u;
    }
    return MG_STATUS_OK;
}
