// One daemon-owned, request-driven process. No timers, project commands or signals.
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void json_string(const char *s, size_t limit) {
    putchar('"');
    for (size_t i = 0; i < limit && s[i]; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') printf("\\%c", c);
        else if (c < 32) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

static void snapshot(void) {
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    struct kinfo_proc *list = NULL;
    size_t size = 0;
    // The process table may grow between sizing and reading. Retry with slack.
    for (int attempt = 0; attempt < 3; attempt++) {
        if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) break;
        size += 128 * sizeof(*list);
        if (size > 16 * 1024 * 1024) break;
        list = malloc(size);
        if (!list) break;
        if (sysctl(mib, 4, list, &size, NULL, 0) == 0) {
            putchar('[');
            int comma = 0;
            for (size_t i = 0; i < size / sizeof(*list); i++) {
                const struct kinfo_proc *p = &list[i];
                if (p->kp_proc.p_pid <= 0 || p->kp_proc.p_stat == SZOMB ||
                    p->kp_proc.p_starttime.tv_sec <= 0) continue;
                printf("%s[%d,%d,%d,%lld,", comma++ ? "," : "",
                       p->kp_proc.p_pid, p->kp_eproc.e_ppid, p->kp_eproc.e_pgid,
                       (long long)p->kp_proc.p_starttime.tv_sec);
                json_string(p->kp_proc.p_comm, sizeof(p->kp_proc.p_comm));
                putchar(']');
            }
            puts("]");
            free(list);
            return;
        }
        free(list);
        list = NULL;
        if (errno != ENOMEM) break;
    }
    puts("null");
}

static void resources(char *input) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    putchar('[');
    int comma = 0;
    char *save = NULL;
    for (char *token = strtok_r(input, " \n", &save); token;
         token = strtok_r(NULL, " \n", &save)) {
        int pid = 0;
        uint64_t start = 0;
        char extra;
        if (sscanf(token, "%d:%" SCNu64 "%c", &pid, &start, &extra) != 2 || pid <= 0) continue;
        struct proc_bsdinfo before = {0}, after = {0};
        struct rusage_info_v0 usage = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before) ||
            before.pbi_status == SZOMB || before.pbi_start_tvsec != start) continue;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&usage) != 0) continue;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after) ||
            after.pbi_status == SZOMB || before.pbi_start_tvsec != after.pbi_start_tvsec ||
            before.pbi_start_tvusec != after.pbi_start_tvusec) continue;
        printf("%s[%d,%" PRIu64 ",%" PRIu64 ",%.6f,%" PRIu64 "]",
               comma++ ? "," : "", pid, start, usage.ri_resident_size,
               (double)(((long double)usage.ri_user_time + usage.ri_system_time) *
                        timebase.numer / timebase.denom / 1000000.0L),
               usage.ri_phys_footprint);
    }
    puts("]");
}

static void own_resources(void) {
    char request[128];
    struct proc_bsdinfo parent = {0}, self = {0};
    if (proc_pidinfo(getppid(), PROC_PIDTBSDINFO, 0, &parent, sizeof(parent)) != sizeof(parent) ||
        proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &self, sizeof(self)) != sizeof(self)) {
        puts("null"); return;
    }
    snprintf(request, sizeof(request), "%d:%" PRIu64 " %d:%" PRIu64,
             getppid(), parent.pbi_start_tvsec, getpid(), self.pbi_start_tvsec);
    resources(request);
}

// Buffer results until the PID identity has been checked again after reading FDs.
struct port_entry { int family; unsigned short port; char address[INET6_ADDRSTRLEN]; };
static void ports(char *input) {
    putchar('[');
    int comma = 0;
    char *save = NULL;
    for (char *token = strtok_r(input, " \n", &save); token;
         token = strtok_r(NULL, " \n", &save)) {
        int pid = 0;
        uint64_t start = 0;
        char extra;
        if (sscanf(token, "%d:%" SCNu64 "%c", &pid, &start, &extra) != 2 || pid <= 0) continue;
        struct proc_bsdinfo before = {0}, after = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before) ||
            before.pbi_status == SZOMB || before.pbi_start_tvsec != start) continue;
        struct proc_fdinfo *fds = NULL;
        int bytes = -1;
        for (int attempt = 0; attempt < 3; attempt++) {
            errno = 0;
            int needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
            if (needed < 0 || (needed == 0 && errno != 0) || needed > 8 * 1024 * 1024) break;
            int capacity = needed + 64 * sizeof(*fds);
            fds = malloc(capacity);
            if (!fds) break;
            errno = 0;
            bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, capacity);
            if (bytes == 0 && errno != 0) bytes = -1;
            if (bytes >= 0 && bytes < capacity) break;
            free(fds); fds = NULL; bytes = -1;
        }
        int count = bytes > 0 ? bytes / sizeof(*fds) : 0;
        struct port_entry *entries = calloc(count + 1, sizeof(*entries));
        int ok = fds != NULL && bytes >= 0 && entries != NULL, found = 0;
        for (int i = 0; ok && i < count; i++) {
            if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo info = {0};
            if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != sizeof(info)) {
                if (errno != EBADF && errno != ENOENT) ok = 0;
                continue;
            }
            if (info.psi.soi_kind != SOCKINFO_TCP || info.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) continue;
            int family = info.psi.soi_family;
            if (family != AF_INET && family != AF_INET6) continue;
            struct in_sockinfo *in = &info.psi.soi_proto.pri_tcp.tcpsi_ini;
            struct port_entry *entry = &entries[found];
            entry->family = family;
            entry->port = ntohs((uint16_t)in->insi_lport);
            const void *address = family == AF_INET ? (const void *)&in->insi_laddr.ina_46.i46a_addr4 : (const void *)&in->insi_laddr.ina_6;
            if (!inet_ntop(family, address, entry->address, sizeof(entry->address))) { ok = 0; break; }
            if (entry->port) found++;
        }
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) == sizeof(after) &&
            after.pbi_status != SZOMB && before.pbi_start_tvsec == after.pbi_start_tvsec &&
            before.pbi_start_tvusec == after.pbi_start_tvusec) {
            printf("%s[%d,%" PRIu64 ",", comma++ ? "," : "", pid, start);
            if (!ok) printf("null");
            else {
                putchar('[');
                for (int i = 0; i < found; i++) {
                    printf("%s[\"%s\",\"%s\",%u]", i ? "," : "",
                           entries[i].family == AF_INET ? "ipv4" : "ipv6", entries[i].address, entries[i].port);
                }
                putchar(']');
            }
            putchar(']');
        }
        free(entries); free(fds);
    }
    puts("]");
}

int main(void) {
    // Requests are internal and bounded; EOF (including daemon death) exits.
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    while ((length = getline(&line, &capacity, stdin)) != -1) {
        if (length > 1024 * 1024) break;
        if (strcmp(line, "S\n") == 0) snapshot();
        else if (strcmp(line, "O\n") == 0) own_resources();
        else if (strncmp(line, "P ", 2) == 0) ports(line + 2);
        else if (strncmp(line, "R ", 2) == 0) resources(line + 2);
        else puts("null");
        if (fflush(stdout) != 0) break;
    }
    free(line);
    return 0;
}
