#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
static void ok(mg_status_t s,mg_error_t **e,const char *w){if(s!=MG_STATUS_OK){fprintf(stderr,"%s status=%d %s\n",w,s,*e?mgErrorMessage(*e):"");_Exit(2);}mgErrorDestroy(*e);*e=NULL;}
static void rejected(mg_graph_exec_t *x,mg_stream_t *s,const char *label){mg_error_t *e=NULL;mg_launch_t *l=NULL;mg_status_t st=mgGraphLaunch(x,s,&l,&e);if(st!=MG_STATUS_INVALID_ARGUMENT||l||!e){fprintf(stderr,"%s expected rejected got %d\n",label,st);_Exit(3);}mgErrorDestroy(e);}
static mg_graph_exec_t *writer(mg_device_t *d,mg_buffer_t *b,mg_event_t *event,bool producer,bool early,uint64_t target){
 mg_error_t *e=NULL;mg_graph_t *g=NULL;mg_graph_exec_t *x=NULL;mg_node_t *f=NULL,*v=NULL;mg_fill_desc_t desc={};desc.size=sizeof(desc);desc.dst=b;desc.byte_count=16;desc.value=producer?0x11:0x22;
 ok(mgGraphCreate(&g,&e),&e,"graph");ok(mgGraphAddFillNode(g,&desc,&f,&e),&e,"fill");
 if(producer)ok(mgGraphAddEventSignalNode(g,event,target,&v,&e),&e,"signal");else ok(mgGraphAddEventWaitNode(g,event,target,&v,&e),&e,"wait");
 bool fillFirst=producer!=early;ok(mgGraphAddDependency(g,fillFirst?f:v,fillFirst?v:f,&e),&e,"edge");ok(mgGraphInstantiate(g,d,&x,&e),&e,"instantiate");mgGraphDestroy(g);return x;
}
static mg_graph_exec_t *self_cycle(mg_device_t *d,mg_buffer_t *b,mg_event_t *event){mg_error_t *e=NULL;mg_graph_t *g=NULL;mg_graph_exec_t *x=NULL;mg_node_t *w=NULL,*f=NULL,*v=NULL;mg_fill_desc_t desc={};desc.size=sizeof(desc);desc.dst=b;desc.byte_count=16;desc.value=0x11;ok(mgGraphCreate(&g,&e),&e,"graph");ok(mgGraphAddEventWaitNode(g,event,1,&w,&e),&e,"wait");ok(mgGraphAddFillNode(g,&desc,&f,&e),&e,"fill");ok(mgGraphAddEventSignalNode(g,event,1,&v,&e),&e,"signal");ok(mgGraphAddDependency(g,w,f,&e),&e,"wait-fill");ok(mgGraphAddDependency(g,f,v,&e),&e,"fill-signal");ok(mgGraphInstantiate(g,d,&x,&e),&e,"instantiate");mgGraphDestroy(g);return x;}
static mg_graph_exec_t *signaler(mg_device_t *d,mg_event_t *event,uint64_t target){mg_error_t *e=NULL;mg_graph_t *g=NULL;mg_graph_exec_t *x=NULL;mg_node_t *n=NULL;ok(mgGraphCreate(&g,&e),&e,"graph");ok(mgGraphAddEventSignalNode(g,event,target,&n,&e),&e,"signal");ok(mgGraphInstantiate(g,d,&x,&e),&e,"instantiate");mgGraphDestroy(g);return x;}
static mg_graph_exec_t *waiter(mg_device_t *d,mg_event_t *event,uint64_t target){mg_error_t *e=NULL;mg_graph_t *g=NULL;mg_graph_exec_t *x=NULL;mg_node_t *n=NULL;ok(mgGraphCreate(&g,&e),&e,"graph");ok(mgGraphAddEventWaitNode(g,event,target,&n,&e),&e,"wait");ok(mgGraphInstantiate(g,d,&x,&e),&e,"instantiate");mgGraphDestroy(g);return x;}
static void wait_value(id<MTLSharedEvent> ev,uint64_t target){for(int i=0;i<2000 && ev.signaledValue<target;i++)usleep(1000);if(ev.signaledValue<target){fprintf(stderr,"event wait timeout\n");_Exit(4);}}
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=2)return 1;bool waiterFirst=!strcmp(argv[1],"waiter-first"),spoof=!strcmp(argv[1],"retired-spoiler"),early=!strcmp(argv[1],"early-signal"),late=!strcmp(argv[1],"late-wait"),sameQueue=!strcmp(argv[1],"same-queue"),wrongTarget=!strcmp(argv[1],"wrong-target"),blocked=!strcmp(argv[1],"blocked-producer"),selfCycle=!strcmp(argv[1],"self-cycle"),producerFail=!strcmp(argv[1],"producer-precommit-failure"),advancingLower=!strcmp(argv[1],"advancing-lower-signal");
 mg_error_t *e=NULL;mg_device_t *d=NULL;mg_stream_t *ps=NULL,*cs=NULL,*is=NULL;mg_event_t *event=NULL;
 mg_status_t st=mgDeviceCreateSystemDefault(&d,&e);if(st==MG_STATUS_UNSUPPORTED)return 77;ok(st,&e,"device");ok(mgStreamCreate(d,&ps,&e),&e,"p stream");ok(mgStreamCreate(d,&cs,&e),&e,"c stream");ok(mgStreamCreate(d,&is,&e),&e,"i stream");ok(mgEventCreate(d,&event,&e),&e,"event");
 id<MTLDevice> metal=(__bridge id<MTLDevice>)d->impl;id<MTLBuffer> native=[metal newBufferWithLength:64 options:MTLResourceStorageModeShared|MTLResourceHazardTrackingModeUntracked];if(!native)return 77;memset(native.contents,0xA5,64);
 mg_metal_buffer_wrap_desc_t wd={};wd.size=sizeof(wd);wd.buffer=native;wd.byte_length=64;wd.access=MG_METAL_BUFFER_ACCESS_READ_WRITE;wd.flags=MG_METAL_BUFFER_WRAP_RETAIN_BUFFER|MG_METAL_BUFFER_WRAP_HOST_VISIBLE|MG_METAL_BUFFER_WRAP_MUTABLE;
 uint64_t target=advancingLower?2:1;
 mg_buffer_t *b=NULL;ok(mgMetalBufferWrap(d,&wd,&b,&e),&e,"wrap");mg_graph_exec_t *p=writer(d,b,event,true,early,target),*c=writer(d,b,event,false,late,wrongTarget?2:target),*hi=signaler(d,event,target+1),*lo=signaler(d,event,advancingLower?1:0);mg_launch_t *pl=NULL,*cl=NULL,*hl=NULL,*ll=NULL;
 dispatch_semaphore_t pHold=dispatch_semaphore_create(0),cHold=dispatch_semaphore_create(0);p->test_completion_hold=(__bridge void *)pHold;c->test_completion_hold=(__bridge void *)cHold;
 mg_event_t *blockEvent=NULL; mg_graph_exec_t *blocker=NULL; mg_launch_t *blockLaunch=NULL;
 if(blocked){ok(mgEventCreate(d,&blockEvent,&e),&e,"block event");blocker=waiter(d,blockEvent,1);ok(mgGraphLaunch(blocker,ps,&blockLaunch,&e),&e,"blocking head");}
 if(waiterFirst||sameQueue||blocked||selfCycle||producerFail||advancingLower){ok(mgGraphLaunch(c,cs,&cl,&e),&e,"consumer first");if(sameQueue)rejected(p,cs,"same queue cycle");
   if(advancingLower){ok(mgGraphLaunch(lo,is,&ll,&e),&e,"advancing lower signal");ok(mgLaunchSynchronize(ll,&e),&e,"lower sync");mgLaunchDestroy(ll);ll=NULL;if(((__bridge id<MTLSharedEvent>)event->impl).signaledValue!=1){fprintf(stderr,"lower signal did not advance event\n");_Exit(11);}}
   if(selfCycle){mg_graph_exec_t *cyclic=self_cycle(d,b,event);rejected(cyclic,ps,"self cycle");mgGraphExecDestroy(cyclic);}
   if(producerFail){mg_test_fail_next_raw_before_commit(p);mg_launch_t *failed=NULL;ok(mgGraphLaunch(p,ps,&failed,&e),&e,"deferred producer launch");st=mgLaunchSynchronize(failed,&e);if(st!=MG_STATUS_BACKEND_ERROR || !e || mgErrorStage(e)!=MG_ERROR_STAGE_COMMIT){fprintf(stderr,"expected deferred producer precommit failure got %d\n",st);_Exit(10);}mgErrorDestroy(e);e=NULL;mgLaunchDestroy(failed);}
   if(blocked){rejected(p,ps,"producer behind waiting head");id<MTLCommandQueue> q=[metal newCommandQueue];id<MTLCommandBuffer> release=[q commandBuffer];[release encodeSignalEvent:(__bridge id<MTLSharedEvent>)blockEvent->impl value:1];[release commit];ok(mgLaunchSynchronize(blockLaunch,&e),&e,"blocked head sync");}
   ok(mgGraphLaunch(p,ps,&pl,&e),&e,"producer second");if(__atomic_load_n(&p->test_certified_count,__ATOMIC_ACQUIRE)==0){fprintf(stderr,"missing producer certificate\n");_Exit(5);}}
 else{
   ok(mgGraphLaunch(p,ps,&pl,&e),&e,"producer first");wait_value((__bridge id<MTLSharedEvent>)event->impl,1);
   if(spoof){ok(mgGraphLaunch(hi,is,&hl,&e),&e,"spoiling signal");ok(mgLaunchSynchronize(hl,&e),&e,"spoiler sync");mgLaunchDestroy(hl);hl=NULL;rejected(c,cs,"retired competing signal");}
   else if(early||late||wrongTarget)rejected(c,cs,early?"early signal":late?"late wait":"wrong target");
   else{
     ok(mgGraphLaunch(c,cs,&cl,&e),&e,"late consumer");if(__atomic_load_n(&c->test_certified_count,__ATOMIC_ACQUIRE)==0){fprintf(stderr,"missing late certificate\n");_Exit(6);}
     rejected(hi,is,"live certificate protection");
   }
 }
 dispatch_semaphore_signal(pHold);dispatch_semaphore_signal(cHold);ok(mgLaunchSynchronize(pl,&e),&e,"producer sync");if(cl)ok(mgLaunchSynchronize(cl,&e),&e,"consumer sync");
 if(!waiterFirst && !sameQueue && !blocked && !selfCycle && !producerFail && !advancingLower && !spoof && !early && !late && !wrongTarget){ok(mgGraphLaunch(hi,is,&hl,&e),&e,"signal after certificate retired");ok(mgLaunchSynchronize(hl,&e),&e,"high sync");mgLaunchDestroy(hl);hl=NULL;}
 if(cl){for(int i=0;i<16;i++)if(((uint8_t *)native.contents)[i]!=0x22){fprintf(stderr,"handoff result mismatch\n");_Exit(7);}}
 for(int i=16;i<64;i++)if(((uint8_t *)native.contents)[i]!=0xA5)_Exit(8);
 mgLaunchDestroy(blockLaunch);mgGraphExecDestroy(blocker);mgEventDestroy(blockEvent);mgLaunchDestroy(pl);mgLaunchDestroy(cl);mgGraphExecDestroy(p);mgGraphExecDestroy(c);mgGraphExecDestroy(hi);mgGraphExecDestroy(lo);mgBufferDestroy(b);mgEventDestroy(event);mgStreamDestroy(ps);mgStreamDestroy(cs);mgStreamDestroy(is);mgDeviceDestroy(d);
 fprintf(stderr,"EVENT_CERTIFICATE mode=%s passed=1\n",argv[1]);return 0;
}}
