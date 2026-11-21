// Authenticated client IOSurface transport. Native send rights never enter JSON.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <servers/bootstrap.h>
#include <bsm/libbsm.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <stdlib.h>

#define GG_MAGIC 0x47504731
struct GGFrame {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    mach_msg_port_descriptor_t proof;
    uint32_t magic, width, height, probe;
    uint64_t sequence;
};
struct GGProof { mach_msg_header_t header; uint8_t bytes[32]; };
struct GGChannel { mach_port_t destination, proof; pid_t peer; uint8_t expected[32]; int verified; };
struct GGReceived { IOSurfaceRef surface; mach_port_t proof; uint64_t sequence; int probe; };
static void gg_drop_receive(mach_port_t port) {
    if (port) mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
}
static void gg_drop_send(mach_port_t port) {
    if (port) mach_port_deallocate(mach_task_self(), port);
}
static mach_port_t gg_port(void) {
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) return 0;
    mach_port_limits_t limits = {2};
    mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
    return port;
}
int gg_peer_pid(int fd) {
    pid_t pid = 0; socklen_t len = sizeof(pid);
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 ? pid : 0;
}
void *gg_receiver_new(char *name, size_t size) {
    uint8_t random[16]; arc4random_buf(random, sizeof(random));
    char hex[33]; for (int i=0;i<16;i++) snprintf(hex+i*2,3,"%02x",random[i]);
    snprintf(name,size,"org.graffitty.gpu.%d.%s",getpid(),hex);
    mach_port_t port = gg_port(); if (!port) return NULL;
    if (mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND)!=KERN_SUCCESS) {gg_drop_receive(port);return NULL;}
    if (bootstrap_register(bootstrap_port,name,port)!=KERN_SUCCESS) {gg_drop_send(port);gg_drop_receive(port);return NULL;}
    gg_drop_send(port);
    return (void *)(uintptr_t)port;
}
void gg_receiver_free(void *receiver) {gg_drop_receive((mach_port_t)(uintptr_t)receiver);}
static int gg_send(struct GGChannel *channel, IOSurfaceRef surface, uint64_t sequence, int probe) {
    mach_port_t right = IOSurfaceCreateMachPort(surface); if (!right) return -1;
    struct GGFrame m = {0};
    m.header.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0);
    m.header.msgh_size = sizeof(m); m.header.msgh_remote_port = channel->destination;
    m.body.msgh_descriptor_count = 2;
    m.surface.name = right; m.surface.disposition = MACH_MSG_TYPE_MOVE_SEND; m.surface.type = MACH_MSG_PORT_DESCRIPTOR;
    m.proof.name = probe ? channel->proof : MACH_PORT_NULL;
    m.proof.disposition = probe ? MACH_MSG_TYPE_MAKE_SEND : MACH_MSG_TYPE_COPY_SEND;
    m.proof.type = MACH_MSG_PORT_DESCRIPTOR;
    m.magic = GG_MAGIC; m.width = (uint32_t)IOSurfaceGetWidth(surface); m.height = (uint32_t)IOSurfaceGetHeight(surface);
    m.sequence = sequence; m.probe = probe;
    kern_return_t result = mach_msg(&m.header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof(m),0,MACH_PORT_NULL,0,MACH_PORT_NULL);
    // A timed-out send hands every right in the message back, possibly under
    // new names, including another reference to the destination.
    //
    // Releasing only `right` leaked one surface right and one destination
    // reference per frame whenever the client stopped draining its two-frame
    // queue: each leaked right kept a whole captured frame alive.
    //
    // Destroying the returned message releases exactly those; the proof
    // receive right stays ours.
    if (result != KERN_SUCCESS) {mach_msg_destroy(&m.header);return result==MACH_SEND_TIMED_OUT?0:-1;}
    return 1;
}
static IOSurfaceRef gg_probe_surface(void) {
    @autoreleasepool {
        return IOSurfaceCreate((CFDictionaryRef)@{(id)kIOSurfaceWidth:@16,(id)kIOSurfaceHeight:@16,
            (id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfaceBytesPerRow:@64,(id)kIOSurfacePixelFormat:@((uint32_t)'BGRA')});
    }
}
void *gg_channel_new(const char *endpoint, int peer) {
    if (peer<=0 || strncmp(endpoint,"org.graffitty.gpu.",strlen("org.graffitty.gpu."))!=0 || strlen(endpoint)>200) return NULL;
    struct GGChannel *c = calloc(1,sizeof(*c)); if (!c) return NULL;
    c->peer=peer; c->proof=gg_port();
    if (!c->proof || bootstrap_look_up(bootstrap_port,endpoint,&c->destination)!=KERN_SUCCESS) goto fail;
    arc4random_buf(c->expected,sizeof(c->expected));
    IOSurfaceRef surface=gg_probe_surface();
    if (!surface) goto fail;
    if (IOSurfaceLock(surface,0,NULL)!=kIOReturnSuccess) {CFRelease(surface);goto fail;}
    memset(IOSurfaceGetBaseAddress(surface),0,IOSurfaceGetAllocSize(surface));
    memcpy(IOSurfaceGetBaseAddress(surface),c->expected,32); IOSurfaceUnlock(surface,0,NULL);
    int sent=gg_send(c,surface,0,1); CFRelease(surface); if (sent!=1) goto fail;
    return c;
fail:
    gg_drop_receive(c->proof);gg_drop_send(c->destination);free(c);return NULL;
}
void gg_channel_free(void *value) {
    struct GGChannel *c=value; if(!c)return;
    gg_drop_receive(c->proof);gg_drop_send(c->destination);memset(c,0,sizeof(*c));free(c);
}
int gg_channel_confirm(void *value) {
    struct GGChannel *c=value; if(c->verified)return 1;
    struct {struct GGProof message; mach_msg_max_trailer_t trailer;} p={0};
    kern_return_t r=mach_msg(&p.message.header,MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),0,sizeof(p),c->proof,0,MACH_PORT_NULL);
    if(r==MACH_RCV_TIMED_OUT)return 0;
    if(r!=KERN_SUCCESS)return -1;
    mach_msg_audit_trailer_t *t=(void *)((uint8_t *)&p+round_msg(p.message.header.msgh_size));
    int valid=p.message.header.msgh_size==sizeof(struct GGProof) && !(p.message.header.msgh_bits&MACH_MSGH_BITS_COMPLEX)
        && t->msgh_trailer_size>=sizeof(*t) && audit_token_to_pid(t->msgh_audit)==c->peer
        && memcmp(p.message.bytes,c->expected,32)==0;
    mach_msg_destroy(&p.message.header);
    if(!valid)return -1;
    c->verified=1;gg_drop_receive(c->proof);c->proof=0;memset(c->expected,0,32);return 1;
}
int gg_channel_send(void *value, void *surface, uint64_t sequence) {
    struct GGChannel *c=value; return c->verified?gg_send(c,surface,sequence,0):-1;
}
// Whether a frame is queued, without receiving it. Safe from any thread: a
// stale name only yields a spurious wake or zero.
int gg_receiver_pending(void *receiver) {
    mach_port_status_t status; mach_msg_type_number_t count = MACH_PORT_RECEIVE_STATUS_COUNT;
    if (mach_port_get_attributes(mach_task_self(), (mach_port_t)(uintptr_t)receiver, MACH_PORT_RECEIVE_STATUS,
        (mach_port_info_t)&status, &count) != KERN_SUCCESS) return 0;
    return status.mps_msgcount > 0;
}
void *gg_receive(void *receiver, int server, int *error) {
    *error=0;
    struct {struct GGFrame message; mach_msg_max_trailer_t trailer;} p={0};
    kern_return_t r=mach_msg(&p.message.header,MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),0,sizeof(p),(mach_port_t)(uintptr_t)receiver,0,MACH_PORT_NULL);
    if(r==MACH_RCV_TIMED_OUT)return NULL;
    if(r!=KERN_SUCCESS){*error=1;return NULL;}
    struct GGFrame *m=&p.message;
    mach_msg_audit_trailer_t *t=(void *)((uint8_t *)&p+round_msg(m->header.msgh_size));
    int valid=server>0 && m->header.msgh_size==sizeof(*m) && (m->header.msgh_bits&MACH_MSGH_BITS_COMPLEX)
        && m->body.msgh_descriptor_count==2 && m->surface.type==MACH_MSG_PORT_DESCRIPTOR
        && m->proof.type==MACH_MSG_PORT_DESCRIPTOR && m->magic==GG_MAGIC && m->probe<=1
        && t->msgh_trailer_size>=sizeof(*t) && audit_token_to_pid(t->msgh_audit)==server;
    IOSurfaceRef surface=valid?IOSurfaceLookupFromMachPort(m->surface.name):NULL;
    valid=surface && m->width>=1 && m->height>=1 && m->width<=8192 && m->height<=8192
        && m->width==IOSurfaceGetWidth(surface) && m->height==IOSurfaceGetHeight(surface)
        && IOSurfaceGetPixelFormat(surface)=='BGRA' && IOSurfaceGetBytesPerElement(surface)==4
        && IOSurfaceGetBytesPerRow(surface)>=(size_t)m->width*4
        && (!m->probe || m->proof.name!=MACH_PORT_NULL);
    struct GGReceived *f=valid?calloc(1,sizeof(*f)):NULL;
    if(f){f->surface=surface;f->sequence=m->sequence;f->probe=m->probe;f->proof=m->proof.name;m->proof.name=MACH_PORT_NULL;}
    else {if(surface)CFRelease(surface);*error=1;}
    mach_msg_destroy(&m->header);return f;
}
void gg_frame_free(void *value) {
    struct GGReceived *f=value; if(!f)return;CFRelease(f->surface);gg_drop_send(f->proof);free(f);
}
void *gg_frame_surface(void *value, uint32_t *w, uint32_t *h,uint64_t *seq,int *probe) {
    struct GGReceived *f=value;*w=(uint32_t)IOSurfaceGetWidth(f->surface);*h=(uint32_t)IOSurfaceGetHeight(f->surface);*seq=f->sequence;*probe=f->probe;
    return (void *)CFRetain(f->surface);
}
void *gg_surface_texture(void *surface, void *device) {
    @autoreleasepool {
        if(!device)return NULL;
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:IOSurfaceGetWidth(surface) height:IOSurfaceGetHeight(surface) mipmapped:NO];
        d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
        return [(id<MTLDevice>)device newTextureWithDescriptor:d iosurface:surface plane:0];
    }
}
// Probe/test path only; chromium frames are imported without CPU readback.
int gg_surface_sample(void *surface, void *device, uint32_t x,uint32_t y,uint32_t count,uint8_t *out) {
    @autoreleasepool {
        if(!device || !count || x+count>IOSurfaceGetWidth(surface) || y>=IOSurfaceGetHeight(surface))return -1;
        id<MTLTexture> texture=gg_surface_texture(surface,device);if(!texture)return -1;
        id<MTLCommandQueue> queue=[(id<MTLDevice>)device newCommandQueue];
        size_t stride=((size_t)count*4+255)&~(size_t)255;
        id<MTLBuffer> buffer=[(id<MTLDevice>)device newBufferWithLength:stride options:MTLResourceStorageModeShared];
        if(!queue || !buffer){[texture release];[queue release];[buffer release];return -1;}
        id<MTLCommandBuffer> commands=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(count,1,1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:stride];
        [blit endEncoding];[commands commit];[commands waitUntilCompleted];
        int result=commands.status==MTLCommandBufferStatusCompleted?0:-1;
        if(result==0)memcpy(out,buffer.contents,count*4);
        [texture release];[buffer release];[queue release];return result;
    }
}
int gg_frame_prove(void *value,void *device) {
    struct GGReceived *f=value;if(!f->probe||!f->proof)return -1;
    struct GGProof m={0};if(gg_surface_sample(f->surface,device,0,0,8,m.bytes)!=0)return -1;
    m.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND,0);m.header.msgh_size=sizeof(m);m.header.msgh_remote_port=f->proof;
    kern_return_t r=mach_msg(&m.header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof(m),0,MACH_PORT_NULL,0,MACH_PORT_NULL);
    // Sent or not, the moved proof right is no longer ours to free.
    if(r!=KERN_SUCCESS)mach_msg_destroy(&m.header);
    f->proof=0;return r==KERN_SUCCESS?0:-1;
}
void *gg_default_device(void) {return MTLCreateSystemDefaultDevice();}
void gg_object_free(void *object) {[(id)object release];}
