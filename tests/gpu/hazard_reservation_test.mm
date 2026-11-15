#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
extern "C" void mg_test_fail_next_raw_after_commit(mg_graph_exec_t *exec);
static void ok(mg_status_t s,mg_error_t **e,const char *w) { if(s!=MG_STATUS_OK){fprintf(stderr,"%s status=%d %s\n",w,s,*e?mgErrorMessage(*e):""); exit(2);}mgErrorDestroy(*e);*e=NULL; }
static mg_buffer_t *wrap(mg_device_t *d,id<MTLBuffer> native) { mg_metal_buffer_wrap_desc_t wd={};wd.size=sizeof(wd);wd.buffer=native;wd.byte_length=64;wd.access=MG_METAL_BUFFER_ACCESS_READ_WRITE;wd.flags=MG_METAL_BUFFER_WRAP_RETAIN_BUFFER|MG_METAL_BUFFER_WRAP_HOST_VISIBLE|MG_METAL_BUFFER_WRAP_MUTABLE;mg_buffer_t *out=NULL;mg_error_t *e=NULL;ok(mgMetalBufferWrap(d,&wd,&out,&e),&e,"wrap");return out; }
static mg_graph_exec_t *make_exec(mg_device_t *d,mg_buffer_t *b,mg_event_t *event,size_t offset,uint8_t value) { mg_error_t *e=NULL; mg_graph_t *g=NULL;mg_graph_exec_t *x=NULL;mg_node_t *f=NULL,*w=NULL;mg_fill_desc_t desc={};desc.size=sizeof(desc);desc.dst=b;desc.dst_offset=offset;desc.byte_count=16;desc.value=value;ok(mgGraphCreate(&g,&e),&e,"graph"); if(event)ok(mgGraphAddEventWaitNode(g,event,1,&w,&e),&e,"wait");ok(mgGraphAddFillNode(g,&desc,&f,&e),&e,"fill");if(event)ok(mgGraphAddDependency(g,w,f,&e),&e,"edge");ok(mgGraphInstantiate(g,d,&x,&e),&e,"instantiate");mgGraphDestroy(g);return x; }
static void reject(mg_graph_exec_t *x,mg_stream_t *s) {
    mg_icb_plan_t original=x->icb;
    x->icb.groups_planned=1; x->icb.groups_used=7; x->icb.groups_fallback=11;
    x->icb.enabled_flags=0; x->icb.last_fallback_reason=MG_ICB_FALLBACK_BACKEND_ERROR;
    mg_error_t *e=NULL;mg_launch_t *l=NULL;mg_status_t st=mgGraphLaunch(x,s,&l,&e);
    if(st!=MG_STATUS_INVALID_ARGUMENT||l||!e||mgErrorStage(e)!=MG_ERROR_STAGE_ENCODE){fprintf(stderr,"hazard was not rejected status=%d\n",st);exit(3);}mgErrorDestroy(e);e=NULL;
    mg_graph_exec_diagnostics_t diag={};diag.size=sizeof(diag);
    ok(mgGraphExecGetDiagnostics(x,&diag,&e),&e,"rejected diagnostics");
    if(diag.icb_groups_used!=7 || diag.icb_groups_fallback!=11 || diag.icb_last_fallback_reason!=MG_ICB_FALLBACK_BACKEND_ERROR){fprintf(stderr,"rejected launch changed ICB diagnostics\n");exit(15);}
    x->icb=original;
}
int main(int argc,char **argv) { @autoreleasepool {
    bool failAfter=argc>1 && strcmp(argv[1],"postcommit")==0;
    bool sameStream=argc>1 && strcmp(argv[1],"same-stream")==0;
    mg_error_t *e=NULL;mg_device_t *d1=NULL,*d2=NULL;mg_stream_t *s1=NULL,*s2=NULL;mg_event_t *event=NULL;
    mg_status_t status=mgDeviceCreateSystemDefault(&d1,&e);if(status==MG_STATUS_UNSUPPORTED)return 77;ok(status,&e,"device1");ok(mgDeviceCreateSystemDefault(&d2,&e),&e,"device2");ok(mgStreamCreate(d1,&s1,&e),&e,"stream1");ok(mgStreamCreate(d2,&s2,&e),&e,"stream2");ok(mgEventCreate(d1,&event,&e),&e,"event");
    id<MTLDevice> metal=(__bridge id<MTLDevice>)d1->impl;id<MTLBuffer> native=[metal newBufferWithLength:64 options:MTLResourceStorageModeShared|MTLResourceHazardTrackingModeUntracked];if(!native)return 77;memset(native.contents,0xA5,64);
    mg_buffer_t *a=wrap(d1,native),*b=wrap(d2,native);mg_graph_exec_t *held=make_exec(d1,a,event,0,0x11),*overlap=make_exec(d2,b,NULL,0,0x22),*touch=make_exec(d2,b,NULL,16,0x33);
    mg_launch_t *first=NULL,*other=NULL;if(failAfter)mg_test_fail_next_raw_after_commit(held);status=mgGraphLaunch(held,s1,&first,&e);
    ok(status,&e,"held launch");
    if(sameStream){
        ok(mgGraphLaunch(overlap,s1,&other,&e),&e,"same-stream overlapping queued launch");
        for(int i=0;i<64;i++)if(((uint8_t *)native.contents)[i]!=0xA5)return 12;
        id<MTLCommandQueue> q=[metal newCommandQueue];id<MTLCommandBuffer> command=[q commandBuffer];
        [command encodeSignalEvent:(__bridge id<MTLSharedEvent>)event->impl value:1];[command commit];
        ok(mgLaunchSynchronize(first,&e),&e,"same-stream first sync");
        ok(mgLaunchSynchronize(other,&e),&e,"same-stream second sync");
        for(int i=0;i<16;i++)if(((uint8_t *)native.contents)[i]!=0x22)return 13;
        for(int i=16;i<64;i++)if(((uint8_t *)native.contents)[i]!=0xA5)return 14;
        mgLaunchDestroy(first);mgLaunchDestroy(other);mgGraphExecDestroy(held);mgGraphExecDestroy(overlap);mgGraphExecDestroy(touch);
        mgBufferDestroy(a);mgBufferDestroy(b);mgEventDestroy(event);mgStreamDestroy(s1);mgStreamDestroy(s2);mgDeviceDestroy(d1);mgDeviceDestroy(d2);
        fprintf(stderr,"same-stream overlapping FIFO passed with exact payload and guards\n");return 0;
    }
    reject(overlap,s2);ok(mgGraphLaunch(touch,s2,&other,&e),&e,"touch launch");ok(mgLaunchSynchronize(other,&e),&e,"touch sync");mgLaunchDestroy(other);other=NULL;
    if(!failAfter){mgLaunchDestroy(first);first=NULL;} /* Reservation must outlive public handle. */
    reject(overlap,s2);
    for(int i=0;i<16;i++)if(((uint8_t *)native.contents)[i]!=0xA5)return 5;
    for(int i=16;i<32;i++)if(((uint8_t *)native.contents)[i]!=0x33)return 6;
    id<MTLCommandQueue> producer=[metal newCommandQueue];id<MTLCommandBuffer> p=[producer commandBuffer];[p encodeSignalEvent:(__bridge id<MTLSharedEvent>)event->impl value:1];[p commit];
    if(failAfter){status=mgLaunchSynchronize(first,&e);if(status!=MG_STATUS_BACKEND_ERROR||!e||mgErrorStage(e)!=MG_ERROR_STAGE_COMMIT){fprintf(stderr,"deferred injected failure missing\n");return 4;}mgErrorDestroy(e);e=NULL;mgLaunchDestroy(first);first=NULL;}
    bool accepted=false;for(int i=0;i<5000;i++){status=mgGraphLaunch(overlap,s2,&other,&e);if(status==MG_STATUS_OK){accepted=true;break;}if(status!=MG_STATUS_INVALID_ARGUMENT)return 7;mgErrorDestroy(e);e=NULL;usleep(1000);}
    if(!accepted){fprintf(stderr,"reservation did not retire\n");return 8;}ok(mgLaunchSynchronize(other,&e),&e,"overlap sync");
    for(int i=0;i<16;i++)if(((uint8_t *)native.contents)[i]!=0x22)return 9;for(int i=16;i<32;i++)if(((uint8_t *)native.contents)[i]!=0x33)return 10;for(int i=32;i<64;i++)if(((uint8_t *)native.contents)[i]!=0xA5)return 11;
    mgLaunchDestroy(other);mgGraphExecDestroy(held);mgGraphExecDestroy(overlap);mgGraphExecDestroy(touch);mgBufferDestroy(a);mgBufferDestroy(b);mgEventDestroy(event);mgStreamDestroy(s1);mgStreamDestroy(s2);mgDeviceDestroy(d1);mgDeviceDestroy(d2);
    fprintf(stderr,"RESERVATION_PROTOTYPE postcommit=%d rejected=1 touching=1 retired=1 guards=1 two-device-handles=1\n",failAfter);return 0;
} }
