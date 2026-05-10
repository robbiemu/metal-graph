#include "metal_graph/metal_graph.h"

#include <string.h>

int main(void) {
    mg_version_t version = mgVersion();
    if (version.major != MG_VERSION_MAJOR || version.minor != MG_VERSION_MINOR ||
        version.patch != MG_VERSION_PATCH) {
        return 1;
    }

    if (strcmp(mgVersionString(), "0.1.0") != 0) {
        return 2;
    }

    if (strcmp(mgStatusString(MG_STATUS_OK), "ok") != 0) {
        return 3;
    }

    return 0;
}
