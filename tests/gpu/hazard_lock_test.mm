#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
static void ok(mg_status_t s,mg_error_t **e,const char *w){if(s!=MG_STATUS_OK){fprintf(stderr,"%s status=%d %s\n",w,s,*e?mgErrorMessage(*e):"");_Exit(2);}mgErrorDestroy(*e);*e=NULL;}
static mg_buffer_t *wrap(mg_device_t *d,id<MTLBuffer> native){mg_error_t *e=NULL;mg_buffer_t *b=NULL;mg_metal_buffer_wrap_desc_t w={};w.size=sizeof(w);w.buffer=native;w.byte_length=64;w.access=MG_METAL_BUFFER_ACCESS_READ_WRITE;w.flags=MG_METAL_BUFFER_WRAP_RETAIN_BUFFER|MG_METAL_BUFFER_WRAP_HOST_VISIBLE|MG_METAL_BUFFER_WRAP_MUTABLE;ok(mgMetalBufferWrap(d,&w,&b,&e),&e,"wrap");return b;}
static mg_graph_exec_t *make(mg_device_t *d,mg_buffer_t *a,mg_buffer_t *b,size_t offset,uint8_t value){mg_error_t *e=NULL;mg_graph_t *g=NULL;mg_graph_exec_t *x=NULL;mg_node_t *n1=NULL,*n2=NULL;mg_fill_desc_t f={};f.size=sizeof(f);f.dst=a;f.dst_offset=offset;f.byte_count=16;f.value=value;ok(mgGraphCreate(&g,&e),&e,"graph");ok(mgGraphAddFillNode(g,&f,&n1,&e),&e,"fill1");f.dst=b;ok(mgGraphAddFillNode(g,&f,&n2,&e),&e,"fill2");ok(mgGraphAddDependency(g,n1,n2,&e),&e,"dependency");ok(mgGraphInstantiate(g,d,&x,&e),&e,"instantiate");mgGraphDestroy(g);return x;}
int main(){@autoreleasepool{
 mg_error_t *e=NULL;mg_device_t *d=NULL;mg_stream_t *s1=NULL,*s2=NULL;mg_status_t st=mgDeviceCreateSystemDefault(&d,&e);if(st==MG_STATUS_UNSUPPORTED)return 77;ok(st,&e,"device");ok(mgStreamCreate(d,&s1,&e),&e,"stream1");ok(mgStreamCreate(d,&s2,&e),&e,"stream2");
 id<MTLDevice> metal=(__bridge id<MTLDevice>)d->impl;id<MTLBuffer> a=[metal newBufferWithLength:64 options:MTLResourceStorageModeShared|MTLResourceHazardTrackingModeUntracked],b=[metal newBufferWithLength:64 options:MTLResourceStorageModeShared|MTLResourceHazardTrackingModeUntracked];if(!a||!b)return 77;memset(a.contents,0xA5,64);memset(b.contents,0x5A,64);
 mg_buffer_t *ma=wrap(d,a),*mb=wrap(d,b);mg_graph_exec_t *x=make(d,ma,mb,0,0x11),*y=make(d,mb,ma,16,0x22);std::atomic<int> ready{0};
 auto run=[&](mg_graph_exec_t *exec,mg_stream_t *stream){@autoreleasepool{ready.fetch_add(1);while(ready.load()!=2)std::this_thread::yield();for(int i=0;i<32;i++){mg_error_t *err=NULL;mg_launch_t *launch=NULL;ok(mgGraphLaunch(exec,stream,&launch,&err),&err,"launch");ok(mgLaunchSynchronize(launch,&err),&err,"sync");mgLaunchDestroy(launch);}}};
 std::thread t1(run,x,s1),t2(run,y,s2);t1.join();t2.join();
 for(int i=0;i<64;i++){uint8_t ea=i<16?0x11:i<32?0x22:0xA5;uint8_t eb=i<16?0x11:i<32?0x22:0x5A;if(((uint8_t *)a.contents)[i]!=ea||((uint8_t *)b.contents)[i]!=eb){fprintf(stderr,"guards/results mismatch i=%d\n",i);return 3;}}
 mgGraphExecDestroy(x);mgGraphExecDestroy(y);mgBufferDestroy(ma);mgBufferDestroy(mb);mgStreamDestroy(s1);mgStreamDestroy(s2);mgDeviceDestroy(d);fprintf(stderr,"LOCK_PROTOTYPE workers=2 rounds=32 opposite-order=1 disjoint=1 guards=1\n");return 0;
}}
