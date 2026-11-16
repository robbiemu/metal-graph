/* Native-object domains own transactional write and event reservations. The whole-job event
 * ordering proof is intentionally conservative; there is no mutable process-wide registry. */
static const char mg_hazard_domain_key = 0;
@interface MGHazardDomain : NSObject
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSRecursiveLock *gate;
@property(nonatomic, strong) NSMutableArray *writers, *jobs, *events, *candidates, *certificates;
@end
@implementation MGHazardDomain
- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _gate = [NSRecursiveLock new];
        _writers = [NSMutableArray new];
        _jobs = [NSMutableArray new];
        _events = [NSMutableArray new];
        _candidates = [NSMutableArray new];
        _certificates = [NSMutableArray new];
        if (!_lock || !_gate || !_writers || !_jobs || !_events || !_candidates || !_certificates)
            return nil;
    }
    return self;
}
@end
@class MGHazardSnapshot;
@interface MGHazardUse : NSObject
@property(nonatomic, strong) MGHazardDomain *domain;
@property(nonatomic, strong) id nativeObject;
@property(nonatomic, weak) MGHazardSnapshot *job;
@property(nonatomic, assign) mg_buffer_t *buffer;
@property(nonatomic, assign) size_t offset, length;
@end
@implementation MGHazardUse
@end
@interface MGHazardEvent : NSObject
@property(nonatomic, strong) id<MTLSharedEvent> native;
@property(nonatomic, strong) MGHazardDomain *domain;
@property(nonatomic, weak) MGHazardSnapshot *job;
@property(nonatomic, assign) uint64_t value;
@property(nonatomic, assign) BOOL signal;
@end
@implementation MGHazardEvent
@end
@interface MGHazardCandidate : NSObject
@property(nonatomic, weak) MGHazardSnapshot *producer;
@property(nonatomic, strong) MGHazardEvent *signal;
@property(nonatomic, assign) BOOL fresh, spoiled;
@end
@implementation MGHazardCandidate
@end
@interface MGHazardCertificate : NSObject
@property(nonatomic, weak) MGHazardSnapshot *producer, *consumer;
@property(nonatomic, assign) uint64_t value;
@end
@implementation MGHazardCertificate
@end
@interface MGHazardSnapshot : NSObject
@property(nonatomic, strong) NSArray<MGHazardUse *> *uses;
@property(nonatomic, strong) NSArray<MGHazardDomain *> *domains;
@property(nonatomic, strong) NSArray<MGHazardEvent *> *events;
@property(nonatomic, strong) MGHazardDomain *queueDomain;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, weak) id scheduler;
@property(nonatomic, strong) MGHazardEvent *wholeWait, *wholeSignal;
@property(nonatomic, strong) MGHazardCandidate *candidate;
@property(nonatomic, assign) BOOL noWaits, runnableHead, registered;
- (void)retire;
@end
@implementation MGHazardSnapshot
- (void)retire {
    NSArray<MGHazardDomain *> *domains = self.domains;
    NSUInteger locked = 0;
    @try {
        for (; locked < domains.count; ++locked)
            [domains[locked].lock lock];
        if (!self.registered)
            return;
        for (MGHazardUse *use in self.uses)
            [use.domain.writers removeObjectIdenticalTo:use];
        for (MGHazardEvent *event in self.events)
            [event.domain.events removeObjectIdenticalTo:event];
        if (self.candidate)
            [self.candidate.signal.domain.candidates removeObjectIdenticalTo:self.candidate];
        [self.queueDomain.jobs removeObjectIdenticalTo:self];
        for (MGHazardDomain *domain in domains) {
            for (NSUInteger i = domain.certificates.count; i > 0; --i) {
                MGHazardCertificate *cert = domain.certificates[i - 1];
                if (cert.producer == self || cert.consumer == self || !cert.producer ||
                    !cert.consumer)
                    [domain.certificates removeObjectAtIndex:i - 1];
            }
        }
        self.registered = NO;
    } @finally {
        while (locked)
            [domains[--locked].lock unlock];
    }
}
@end
static MGHazardDomain *mg_hazard_domain(id object) {
    @synchronized(object) {
        MGHazardDomain *domain = objc_getAssociatedObject(object, &mg_hazard_domain_key);
        if (!domain) {
            domain = [MGHazardDomain new];
            if (domain)
                objc_setAssociatedObject(object, &mg_hazard_domain_key, domain,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return domain;
    }
}
struct MGQueueGuard {
    __strong NSRecursiveLock *lock;
    bool held;
    MGQueueGuard() : lock(nil), held(false) {}
    explicit MGQueueGuard(NSRecursiveLock *l) : lock(nil), held(false) { acquire(l); }
    void acquire(NSRecursiveLock *l) {
        lock = l;
        if (lock) {
            [lock lock];
            held = true;
        }
    }
    void release() {
        if (held) {
            [lock unlock];
            held = false;
        }
    }
    ~MGQueueGuard() { release(); }
};
static bool mg_hazard_append(NSMutableArray<MGHazardUse *> *uses, mg_buffer_t *buffer,
                             size_t relative, size_t count) {
    if (!buffer || !buffer->impl || relative > buffer->length ||
        count > buffer->length - relative || buffer->byte_offset > SIZE_MAX - relative)
        return false;
    if (!count)
        return true; /* No accessible bytes remain in this valid binding range. */
    id<MTLBuffer> native = (__bridge id<MTLBuffer>)buffer->impl;
    id identity = native.heap ? (id)native.heap : (id)native;
    MGHazardDomain *domain = mg_hazard_domain(identity);
    MGHazardUse *use = [MGHazardUse new];
    if (!domain || !use)
        return false;
    use.domain = domain;
    use.nativeObject = native;
    use.buffer = buffer;
    use.offset = buffer->byte_offset + relative;
    use.length = count;
    [uses addObject:use];
    return true;
}
static bool mg_hazard_endpoints(mg_graph_exec_t *exec, size_t *source, size_t *sink) {
    size_t n = exec->node_count;
    *source = SIZE_MAX;
    *sink = SIZE_MAX;
    if (!n)
        return true;
    uint8_t *incoming = (uint8_t *)calloc(n, 1), *outgoing = (uint8_t *)calloc(n, 1);
    if (!incoming || !outgoing) {
        free(incoming);
        free(outgoing);
        return false;
    }
    for (size_t e = 0; e < exec->edge_count; e++) {
        size_t before = exec->edges[e].before, after = exec->edges[e].after;
        if (before >= n || after >= n || before >= after) {
            free(incoming);
            free(outgoing);
            return false;
        }
        outgoing[before] = 1;
        incoming[after] = 1;
    }
    /* In a finite DAG every node reaches a sink and is reachable from a source. */
    size_t sources = 0, sinks = 0;
    for (size_t i = 0; i < n; i++) {
        if (!incoming[i]) {
            *source = i;
            ++sources;
        }
        if (!outgoing[i]) {
            *sink = i;
            ++sinks;
        }
    }
    if (sources != 1)
        *source = SIZE_MAX;
    if (sinks != 1)
        *sink = SIZE_MAX;
    free(incoming);
    free(outgoing);
    return true;
}
extern "C" bool mg_test_hazard_reaches_all(mg_graph_exec_t *exec, size_t index, bool toEvent) {
    size_t source, sink;
    return mg_hazard_endpoints(exec, &source, &sink) && index == (toEvent ? sink : source);
}
static bool mg_hazard_certify(MGHazardSnapshot *producer, MGHazardSnapshot *consumer,
                              NSMutableArray *staged) {
    MGHazardCandidate *candidate = producer.candidate;
    MGHazardEvent *wait = consumer.wholeWait;
    /* Identity and immutable target are checked before mutable candidate fields:
     * only a matching event domain is guaranteed locked by this transaction. */
    if (!candidate || !wait || candidate.signal.native != wait.native ||
        candidate.signal.value != wait.value)
        return false;
    if (!candidate.fresh || candidate.spoiled || !producer.runnableHead || !producer.noWaits ||
        producer.queue == consumer.queue)
        return false;
    for (MGHazardEvent *event in consumer.events)
        if (event.signal && event.native == wait.native && event.value >= wait.value)
            return false;
    MGHazardDomain *domain = candidate.signal.domain;
    for (MGHazardCertificate *cert in domain.certificates)
        if (cert.producer == producer && cert.consumer == consumer)
            return true;
    for (NSArray *pair in staged) {
        MGHazardCertificate *cert = pair[1];
        if (cert.producer == producer && cert.consumer == consumer)
            return true;
    }
    MGHazardCertificate *cert = [MGHazardCertificate new];
    if (!cert)
        return false;
    cert.producer = producer;
    cert.consumer = consumer;
    cert.value = wait.value;
    [staged addObject:@[ domain, cert ]];
    return true;
}
/* FIFO orders jobs on one scheduler unless the earlier job is waiting for a signal
 * that only the later job would provide. Matched event domains are transaction-locked. */
static bool mg_hazard_fifo_ordered(MGHazardSnapshot *prior, MGHazardSnapshot *next) {
    if (!prior.scheduler || prior.scheduler != next.scheduler)
        return false;
    for (MGHazardEvent *wait in prior.events)
        if (!wait.signal && wait.native.signaledValue < wait.value)
            for (MGHazardEvent *signal in next.events)
                if (signal.signal && signal.native == wait.native && signal.value >= wait.value)
                    return false;
    return true;
}
static MGHazardSnapshot *mg_hazard_admit(mg_graph_exec_t *exec, id<MTLCommandQueue> queue,
                                         id scheduler, bool *conflict) {
    *conflict = false;
    @try {
        NSMutableArray<MGHazardUse *> *uses = [NSMutableArray new];
        for (size_t i = 0; i < exec->node_count; i++) {
            mg_exec_node_t *node = &exec->nodes[i];
            switch (node->kind) {
            case MG_NODE_DISPATCH:
                for (uint32_t j = 0; j < node->as.dispatch.buffer_count; j++) {
                    mg_buffer_binding_t *binding = &node->as.dispatch.buffers[j];
                    const mg_dispatch_resource_desc_t *r =
                        mg_dispatch_find_resource(node->as.dispatch.resources,
                                                  node->as.dispatch.resource_count, binding->index);
                    if (r && r->access == MG_RESOURCE_ACCESS_READ)
                        continue;
                    size_t offset = binding->offset;
                    if (offset > binding->buffer->length)
                        return nil;
                    if (r) {
                        if (r->byte_offset > SIZE_MAX - offset)
                            return nil;
                        offset += r->byte_offset;
                    }
                    if (offset > binding->buffer->length)
                        return nil;
                    size_t count =
                        r && r->byte_count ? r->byte_count : binding->buffer->length - offset;
                    if (!mg_hazard_append(uses, binding->buffer, offset, count))
                        return nil;
                }
                break;
            case MG_NODE_COPY:
                if (!mg_hazard_append(uses, node->as.copy.dst, node->as.copy.dst_offset,
                                      node->as.copy.byte_count))
                    return nil;
                break;
            case MG_NODE_FILL:
                if (!mg_hazard_append(uses, node->as.fill.dst, node->as.fill.dst_offset,
                                      node->as.fill.byte_count))
                    return nil;
                break;
            case MG_NODE_MPSGRAPH:
                for (uint32_t j = 0; j < node->as.mpsgraph.target_count; j++) {
                    mg_mpsgraph_tensor_t *t = &node->as.mpsgraph.targets[j];
                    if (!mg_hazard_append(uses, t->buffer, t->byte_offset, t->byte_count))
                        return nil;
                }
                break;
            default:
                if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL &&
                    !mg_hazard_append(uses, node->as.workspace_fill.dst,
                                      node->as.workspace_fill.dst_offset,
                                      node->as.workspace_fill.size))
                    return nil;
                break;
            }
        }
        NSMutableArray<MGHazardDomain *> *domains = [NSMutableArray new];
        NSMutableArray<MGHazardEvent *> *events = [NSMutableArray new];
        MGHazardDomain *queueDomain = mg_hazard_domain(queue);
        if (!queueDomain)
            return nil;
        [domains addObject:queueDomain];
        for (MGHazardUse *use in uses)
            if (![domains containsObject:use.domain])
                [domains addObject:use.domain];
        bool noWaits = true, endpointsReady = false;
        size_t source = SIZE_MAX, sink = SIZE_MAX;
        NSUInteger wholeSignal = NSNotFound, wholeWait = NSNotFound, signalCount = 0;
        for (size_t i = 0; i < exec->node_count; i++) {
            mg_exec_node_t *node = &exec->nodes[i];
            if (node->kind != MG_NODE_EVENT_WAIT && node->kind != MG_NODE_EVENT_SIGNAL)
                continue;
            if (!endpointsReady) {
                if (!mg_hazard_endpoints(exec, &source, &sink))
                    return nil;
                endpointsReady = true;
            }
            id<MTLSharedEvent> native = (__bridge id<MTLSharedEvent>)node->as.event.event->impl;
            MGHazardEvent *event = [MGHazardEvent new];
            if (!event || !native)
                return nil;
            event.native = native;
            event.domain = mg_hazard_domain(native);
            if (!event.domain)
                return nil;
            event.value = node->as.event.value;
            event.signal = node->kind == MG_NODE_EVENT_SIGNAL;
            [events addObject:event];
            if (![domains containsObject:event.domain])
                [domains addObject:event.domain];
            if (event.signal) {
                signalCount++;
                if (i == sink)
                    wholeSignal = events.count - 1;
            } else {
                noWaits = false;
                if (i == source)
                    wholeWait = events.count - 1;
            }
        }
        [domains sortUsingComparator:^NSComparisonResult(MGHazardDomain *a, MGHazardDomain *b) {
          uintptr_t x = (uintptr_t)(__bridge void *)a, y = (uintptr_t)(__bridge void *)b;
          return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
        }];
        MGHazardSnapshot *snapshot = [MGHazardSnapshot new];
        if (!snapshot)
            return nil;
        snapshot.uses = uses;
        snapshot.domains = domains;
        snapshot.events = events;
        snapshot.queue = queue;
        snapshot.scheduler = scheduler;
        snapshot.queueDomain = queueDomain;
        snapshot.noWaits = noWaits;
        if (signalCount == 1 && wholeSignal != NSNotFound)
            snapshot.wholeSignal = events[wholeSignal];
        if (wholeWait != NSNotFound)
            snapshot.wholeWait = events[wholeWait];
        for (MGHazardUse *use in uses)
            use.job = snapshot;
        for (MGHazardEvent *event in events)
            event.job = snapshot;
        if (snapshot.wholeSignal && noWaits) {
            snapshot.candidate = [MGHazardCandidate new];
            if (!snapshot.candidate)
                return nil;
            snapshot.candidate.producer = snapshot;
            snapshot.candidate.signal = snapshot.wholeSignal;
        }
        NSMutableArray *staged = [NSMutableArray new];
        if (!staged)
            return nil;
        BOOL failed = NO, allLocked = NO;
        NSUInteger locked = 0;
        @try {
            for (; locked < domains.count; ++locked)
                [domains[locked].lock lock];
            allLocked = YES;
            snapshot.runnableHead = queueDomain.jobs.count == 0;
            if (snapshot.candidate) {
                MGHazardCandidate *c = snapshot.candidate;
                c.fresh = c.signal.native.signaledValue < c.signal.value;
                for (MGHazardEvent *event in c.signal.domain.events)
                    if (event.signal && event.value >= c.signal.value)
                        c.fresh = NO;
            }
            for (MGHazardEvent *event in events)
                if (event.signal) {
                    for (MGHazardCertificate *cert in event.domain.certificates)
                        if (cert.producer && cert.consumer && event.value >= cert.value) {
                            *conflict = true;
                            break;
                        }
                    if (*conflict)
                        break;
                }
            if (!*conflict)
                for (MGHazardUse *use in uses) {
                    for (MGHazardUse *active in use.domain.writers)
                        if (mg_backend_physical_overlap(use.buffer, use.offset, use.length,
                                                        active.buffer, active.offset,
                                                        active.length)) {
                            MGHazardSnapshot *prior = active.job;
                            if (!prior || !(mg_hazard_fifo_ordered(prior, snapshot) ||
                                            mg_hazard_certify(prior, snapshot, staged) ||
                                            mg_hazard_certify(snapshot, prior, staged))) {
                                *conflict = true;
                                break;
                            }
                        }
                    if (*conflict)
                        break;
                }
            if (!*conflict) {
                for (MGHazardUse *use in uses)
                    [use.domain.writers addObject:use];
                for (MGHazardEvent *event in events)
                    [event.domain.events addObject:event];
                [queueDomain.jobs addObject:snapshot];
                if (snapshot.candidate)
                    [snapshot.candidate.signal.domain.candidates addObject:snapshot.candidate];
                for (NSArray *pair in staged)
                    [((MGHazardDomain *)pair[0]).certificates addObject:pair[1]];
                /* Commit spoiling only once admission succeeds. */
                for (MGHazardEvent *event in events)
                    if (event.signal)
                        for (MGHazardCandidate *c in event.domain.candidates)
                            if (c.producer != snapshot && event.value >= c.signal.value)
                                c.spoiled = YES;
                snapshot.registered = YES;
                __atomic_store_n(&exec->test_certified_count, (uint32_t)staged.count,
                                 __ATOMIC_RELEASE);
            }
        } @catch (NSException *exception) {
            (void)exception;
            failed = YES;
        } @finally {
            @try {
                if (allLocked && (failed || *conflict)) {
                    for (MGHazardUse *use in uses)
                        [use.domain.writers removeObjectIdenticalTo:use];
                    for (MGHazardEvent *event in events)
                        [event.domain.events removeObjectIdenticalTo:event];
                    [queueDomain.jobs removeObjectIdenticalTo:snapshot];
                    if (snapshot.candidate)
                        [snapshot.candidate.signal.domain.candidates
                            removeObjectIdenticalTo:snapshot.candidate];
                    for (NSArray *pair in staged)
                        [((MGHazardDomain *)pair[0]).certificates removeObjectIdenticalTo:pair[1]];
                }
            } @finally {
                while (locked)
                    [domains[--locked].lock unlock];
            }
        }
        if (failed)
            return nil;
        return snapshot;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

/* Test-only preflight; no command buffer is created or committed. */
int mg_test_hazard_admission_only(mg_graph_exec_t *exec, mg_stream_t *stream) {
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)stream->impl;
    MGHazardDomain *domain = mg_hazard_domain(queue);
    if (!domain)
        return 0;
    MGQueueGuard guard(domain.gate);
    bool conflict = false;
    MGHazardSnapshot *snapshot =
        mg_hazard_admit(exec, queue, (__bridge id)stream->scheduler_impl, &conflict);
    [snapshot retire];
    return snapshot && !conflict;
}
