#include "metal_graph/metal_graph.h"
#include <stdint.h>
#include <stdio.h>
/* The Objective-C extension is represented by ABI-compatible opaque object pointers here. */
extern mg_status_t mgMetalEventWrap(mg_device_t *, void *, mg_event_t **, mg_error_t **);
extern mg_status_t mgMetalEventGetSharedEvent(const mg_event_t *, void **, mg_error_t **);
int main(void) {
    mg_error_t *error = NULL; mg_event_t *event = (mg_event_t *)(uintptr_t)1;
    mg_status_t status = mgMetalEventWrap((mg_device_t *)(uintptr_t)1, (void *)(uintptr_t)1, &event, &error);
    if (status != MG_STATUS_UNSUPPORTED || event || !error || mgErrorStage(error) != MG_ERROR_STAGE_CREATE) return 1;
    mgErrorDestroy(error); error = NULL;
    void *native = (void *)(uintptr_t)1;
    status = mgMetalEventGetSharedEvent((mg_event_t *)(uintptr_t)1, &native, &error);
    if (status != MG_STATUS_UNSUPPORTED || native || !error || mgErrorStage(error) != MG_ERROR_STAGE_CREATE) return 2;
    mgErrorDestroy(error); error = NULL; event = (mg_event_t *)(uintptr_t)1;
    status = mgMetalEventWrap(NULL, NULL, &event, &error);
    if (status != MG_STATUS_INVALID_ARGUMENT || event || !error) return 3;
    mgErrorDestroy(error); error = NULL; native = (void *)(uintptr_t)1;
    status = mgMetalEventGetSharedEvent(NULL, &native, &error);
    if (status != MG_STATUS_INVALID_ARGUMENT || native || !error) return 4;
    mgErrorDestroy(error); puts("portable event bridge symbols and errors passed"); return 0;
}
