#include "metal_graph/metal_graph.h"

int main() {
    mg_version_t version = mgVersion();
    return version.major == MG_VERSION_MAJOR ? 0 : 1;
}
