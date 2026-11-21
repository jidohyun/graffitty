#include <libproc.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>

// A deliberately small ABI: no platform structs cross into Rust.
struct trm_usage {
    uint64_t start, user_ns, system_ns, memory, peak;
    uint32_t parent, zombie;
    char name[64];
};

static uint64_t ticks_to_ns(uint64_t ticks) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (uint64_t)(((__uint128_t)ticks * tb.numer) / tb.denom);
}

int trm_usage(int pid, struct trm_usage *out) {
    struct rusage_info_v4 r = {0};
    struct proc_bsdinfo b = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&r) != 0)
        return errno ? errno : ESRCH;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b))
        return errno ? errno : ESRCH;
    memset(out, 0, sizeof(*out));
    out->start = r.ri_proc_start_abstime;
    out->user_ns = ticks_to_ns(r.ri_user_time + r.ri_child_user_time);
    out->system_ns = ticks_to_ns(r.ri_system_time + r.ri_child_system_time);
    out->memory = r.ri_phys_footprint;
    out->peak = r.ri_lifetime_max_phys_footprint;
    out->parent = b.pbi_ppid;
    out->zombie = b.pbi_status == 5; // SZOMB: include CPU until reaped, not memory.
    proc_name(pid, out->name, sizeof(out->name));
    return 0;
}

int trm_children(int pid, int *out, int bytes) { return proc_listchildpids(pid, out, bytes); }
