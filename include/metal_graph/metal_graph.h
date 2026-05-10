#ifndef METAL_GRAPH_METAL_GRAPH_H
#define METAL_GRAPH_METAL_GRAPH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MG_VERSION_MAJOR 0
#define MG_VERSION_MINOR 1
#define MG_VERSION_PATCH 0

#if defined(_WIN32)
#  if defined(MG_BUILD_SHARED)
#    define MG_API __declspec(dllexport)
#  elif defined(MG_USE_SHARED)
#    define MG_API __declspec(dllimport)
#  else
#    define MG_API
#  endif
#else
#  define MG_API __attribute__((visibility("default")))
#endif

typedef struct mg_device mg_device_t;
typedef struct mg_stream mg_stream_t;
typedef struct mg_graph mg_graph_t;
typedef struct mg_graph_exec mg_graph_exec_t;
typedef struct mg_launch mg_launch_t;
typedef struct mg_node mg_node_t;
typedef struct mg_buffer mg_buffer_t;
typedef struct mg_event mg_event_t;
typedef struct mg_error mg_error_t;

typedef enum mg_status {
    MG_STATUS_OK = 0,
    MG_STATUS_INVALID_ARGUMENT = 1,
    MG_STATUS_INVALID_TOPOLOGY = 2,
    MG_STATUS_UNSUPPORTED = 3,
    MG_STATUS_OUT_OF_MEMORY = 4,
    MG_STATUS_BACKEND_ERROR = 5,
    MG_STATUS_INTERNAL_ERROR = 6
} mg_status_t;

typedef enum mg_node_kind {
    MG_NODE_DISPATCH = 1,
    MG_NODE_COPY = 2,
    MG_NODE_FILL = 3,
    MG_NODE_EVENT_WAIT = 4,
    MG_NODE_EVENT_SIGNAL = 5,
    MG_NODE_BARRIER = 6,
    MG_NODE_HOST = 7,
    MG_NODE_SUBGRAPH = 8
} mg_node_kind_t;

typedef struct mg_version {
    uint32_t major;
    uint32_t minor;
    uint32_t patch;
} mg_version_t;

MG_API mg_version_t mg_version(void);
MG_API const char *mg_version_string(void);
MG_API const char *mg_status_string(mg_status_t status);

#ifdef __cplusplus
}
#endif

#endif
