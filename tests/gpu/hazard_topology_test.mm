#include "../../src/core/internal.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
extern "C" bool mg_test_hazard_reaches_all(mg_graph_exec_t *, size_t, bool);
int main() {
    unsigned seed = 0x12ac345u;
    for (unsigned trial = 0; trial < 2000; ++trial) {
        size_t n = 1 + (trial % 24);
        std::vector<mg_edge_t> edges;
        std::vector<unsigned char> reach(n * n, 0);
        for (size_t i = 0; i < n; i++)
            for (size_t j = i + 1; j < n; j++) {
                seed = seed * 1664525u + 1013904223u;
                if ((seed >> 28) < 3) {
                    mg_edge_t edge = {};
                    edge.before = i;
                    edge.after = j;
                    edges.push_back(edge);
                    reach[i * n + j] = 1;
                }
            }
        for (size_t k = 0; k < n; k++)
            for (size_t i = 0; i < n; i++)
                for (size_t j = 0; j < n; j++)
                    reach[i * n + j] |= reach[i * n + k] && reach[k * n + j];
        mg_graph_exec_t exec = {};
        exec.node_count = n;
        exec.edges = edges.data();
        exec.edge_count = edges.size();
        for (size_t i = 0; i < n; i++)
            for (int toEvent = 0; toEvent < 2; toEvent++) {
                bool expected = true;
                for (size_t j = 0; j < n; j++)
                    if (i != j && !(toEvent ? reach[j * n + i] : reach[i * n + j]))
                        expected = false;
                if (mg_test_hazard_reaches_all(&exec, i, toEvent) != expected) {
                    fprintf(stderr, "DAG mismatch trial=%u index=%zu\n", trial, i);
                    return 1;
                }
            }
    }
    const size_t n = 50000;
    std::vector<mg_edge_t> edges(n - 1);
    for (size_t i = 0; i + 1 < n; i++) {
        edges[i].before = i;
        edges[i].after = i + 1;
    }
    mg_graph_exec_t exec = {};
    exec.node_count = n;
    exec.edges = edges.data();
    exec.edge_count = edges.size();
    if (!mg_test_hazard_reaches_all(&exec, 0, false) ||
        !mg_test_hazard_reaches_all(&exec, n - 1, true) ||
        mg_test_hazard_reaches_all(&exec, n / 2, false))
        return 2;
    mg_device_t *device = NULL;
    mg_event_t *event = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *ordered = NULL;
    mg_node_t *signal = NULL, *barrier = NULL, *wait = NULL;
    mg_error_t *error = NULL;
    mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
    if (status == MG_STATUS_UNSUPPORTED) {
        mgErrorDestroy(error);
        return 77;
    }
    if (status != MG_STATUS_OK || mgEventCreate(device, &event, &error) != MG_STATUS_OK ||
        mgGraphCreate(&graph, &error) != MG_STATUS_OK ||
        mgGraphAddEventSignalNode(graph, event, 1, &signal, &error) != MG_STATUS_OK ||
        mgGraphAddBarrierNode(graph, &barrier, &error) != MG_STATUS_OK ||
        mgGraphAddEventWaitNode(graph, event, 1, &wait, &error) != MG_STATUS_OK ||
        mgGraphAddDependency(graph, wait, barrier, &error) != MG_STATUS_OK ||
        mgGraphAddDependency(graph, barrier, signal, &error) != MG_STATUS_OK ||
        mgGraphInstantiate(graph, device, &ordered, &error) != MG_STATUS_OK)
        return 3;
    if (ordered->node_count != 3 || ordered->nodes[0].kind != MG_NODE_EVENT_WAIT ||
        ordered->nodes[2].kind != MG_NODE_EVENT_SIGNAL ||
        !mg_test_hazard_reaches_all(ordered, 0, false) ||
        !mg_test_hazard_reaches_all(ordered, 2, true))
        return 4;
    mgGraphExecDestroy(ordered);
    mgGraphDestroy(graph);
    mgEventDestroy(event);
    mgDeviceDestroy(device);
    puts("event topology oracle: 2000 random DAGs, 50000-node chain and reversed creation passed");
    return 0;
}
