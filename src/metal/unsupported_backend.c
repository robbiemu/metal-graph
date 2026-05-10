#include "../core/internal.h"

#include <stdlib.h>

mg_status_t mgDeviceCreateSystemDefault(mg_device_t **out_device, mg_error_t **out_error) {
    if (out_device) {
        *out_device = NULL;
    }
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_CREATE, MG_NODE_ID_INVALID,
                        "Metal backend is only available on Apple platforms", NULL);
}

void mg_backend_device_destroy(mg_device_t *device) { (void)device; }

void mgDeviceDestroy(mg_device_t *device) { free(device); }

mg_status_t mgStreamCreate(mg_device_t *device, mg_stream_t **out_stream, mg_error_t **out_error) {
    (void)device;
    if (out_stream) {
        *out_stream = NULL;
    }
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_CREATE, MG_NODE_ID_INVALID,
                        "Metal backend is only available on Apple platforms", NULL);
}

void mg_backend_stream_destroy(mg_stream_t *stream) { (void)stream; }

void mgStreamDestroy(mg_stream_t *stream) { free(stream); }

mg_status_t mgBufferCreateShared(mg_device_t *device, size_t length, mg_buffer_t **out_buffer,
                                 mg_error_t **out_error) {
    (void)device;
    (void)length;
    if (out_buffer) {
        *out_buffer = NULL;
    }
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_CREATE, MG_NODE_ID_INVALID,
                        "Metal backend is only available on Apple platforms", NULL);
}

void mg_backend_buffer_destroy(mg_buffer_t *buffer) { (void)buffer; }

void *mg_backend_buffer_contents(mg_buffer_t *buffer) {
    (void)buffer;
    return NULL;
}

mg_status_t mgEventCreate(mg_device_t *device, mg_event_t **out_event, mg_error_t **out_error) {
    (void)device;
    if (out_event) {
        *out_event = NULL;
    }
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_CREATE, MG_NODE_ID_INVALID,
                        "Metal shared events are only available on Apple platforms", NULL);
}

void mg_backend_event_destroy(mg_event_t *event) { (void)event; }

mg_status_t mgGraphInstantiate(mg_graph_t *graph, mg_device_t *device, mg_graph_exec_t **out_exec,
                               mg_error_t **out_error) {
    (void)graph;
    (void)device;
    if (out_exec) {
        *out_exec = NULL;
    }
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_INSTANTIATE,
                        MG_NODE_ID_INVALID, "Metal backend is only available on Apple platforms",
                        NULL);
}

void mg_backend_graph_exec_destroy(mg_graph_exec_t *exec) { (void)exec; }

void mgGraphExecDestroy(mg_graph_exec_t *exec) { free(exec); }

mg_status_t mgGraphLaunch(mg_graph_exec_t *exec, mg_stream_t *stream, mg_launch_t **out_launch,
                          mg_error_t **out_error) {
    (void)exec;
    (void)stream;
    if (out_launch) {
        *out_launch = NULL;
    }
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_ENCODE, MG_NODE_ID_INVALID,
                        "Metal backend is only available on Apple platforms", NULL);
}

mg_status_t mgLaunchSynchronize(mg_launch_t *launch, mg_error_t **out_error) {
    (void)launch;
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_SYNC, MG_NODE_ID_INVALID,
                        "Metal backend is only available on Apple platforms", NULL);
}

void mg_backend_launch_destroy(mg_launch_t *launch) { (void)launch; }

void mgLaunchDestroy(mg_launch_t *launch) { free(launch); }
