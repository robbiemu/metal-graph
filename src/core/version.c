#include "metal_graph/metal_graph.h"

mg_version_t mg_version(void) {
    mg_version_t version = {
        MG_VERSION_MAJOR,
        MG_VERSION_MINOR,
        MG_VERSION_PATCH,
    };
    return version;
}

const char *mg_version_string(void) { return "0.1.0"; }

const char *mg_status_string(mg_status_t status) {
    switch (status) {
    case MG_STATUS_OK:
        return "ok";
    case MG_STATUS_INVALID_ARGUMENT:
        return "invalid argument";
    case MG_STATUS_INVALID_TOPOLOGY:
        return "invalid topology";
    case MG_STATUS_UNSUPPORTED:
        return "unsupported";
    case MG_STATUS_OUT_OF_MEMORY:
        return "out of memory";
    case MG_STATUS_BACKEND_ERROR:
        return "backend error";
    case MG_STATUS_INTERNAL_ERROR:
        return "internal error";
    default:
        return "unknown status";
    }
}
