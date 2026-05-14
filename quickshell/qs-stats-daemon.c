/*
 * qs-stats-daemon — event-driven system stats source for quickshell Bar.qml
 *
 * Build:  clang -O2 -Wall -Wextra -o qs-stats-daemon qs-stats-daemon.c
 * Run:    qs-stats-daemon [fifo-path]
 *           default fifo: $TMPDIR/qs-stats.pipe, fallback /tmp/qs-stats.pipe
 *
 * Output protocol (one line per emit, newline-terminated):
 *   cpu <pct>
 *   ram <pct>
 *   disk <pct>
 *   bat <pct> <status>
 *   net <iface> [ssid]
 *   vol <pct> <yes|no>
 *
 * Sources:
 *   - timerfd 10s tick   -> cpu, ram          (no kernel event source)
 *   - timerfd 60s tick   -> disk              (cheap, mostly static)
 *   - netlink uevent     -> battery, net link (kernel hotplug)
 *   - pactl subscribe    -> volume + mute     (PulseAudio change events)
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <linux/netlink.h>

#define BUF 4096

static volatile sig_atomic_t want_exit = 0;
static int fifo_fd = -1;
static char fifo_path[512];

/* ----------------------------- output ----------------------------- */

static void open_fifo(void) {
    if (fifo_fd >= 0) close(fifo_fd);
    /* O_RDWR keeps fd valid even with no reader; writes are silently
     * buffered to pipe cap and dropped when full. Suits a stats stream. */
    fifo_fd = open(fifo_path, O_RDWR | O_NONBLOCK);
    if (fifo_fd < 0) {
        fprintf(stderr, "qs-stats-daemon: open %s: %s\n",
                fifo_path, strerror(errno));
    }
}

static void emit(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n >= (int)sizeof(buf) - 1) n = sizeof(buf) - 2;
    if (buf[n - 1] != '\n') { buf[n++] = '\n'; }

    if (fifo_fd < 0) open_fifo();
    if (fifo_fd < 0) return;

    ssize_t w = write(fifo_fd, buf, (size_t)n);
    if (w < 0) {
        if (errno == EPIPE || errno == EBADF) open_fifo();
        /* EAGAIN = pipe full, drop */
    }
}

/* ----------------------------- cpu/ram/disk ----------------------------- */

static unsigned long long prev_total = 0, prev_idle = 0;

static void poll_cpu(void) {
    FILE *f = fopen("/proc/stat", "r");
    if (!f) return;
    unsigned long long u, n, s, i, w, q, sirq;
    if (fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu",
               &u, &n, &s, &i, &w, &q, &sirq) != 7) {
        fclose(f);
        return;
    }
    fclose(f);
    unsigned long long total = u + n + s + i + w + q + sirq;
    unsigned long long idle = i;
    if (prev_total > 0 && total > prev_total) {
        unsigned long long dt = total - prev_total;
        unsigned long long di = idle - prev_idle;
        int pct = (int)(((dt - di) * 100) / dt);
        emit("cpu %d", pct);
    }
    prev_total = total;
    prev_idle = idle;
}

static void poll_ram(void) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return;
    unsigned long total = 0, avail = 0;
    char k[64];
    unsigned long v;
    while (fscanf(f, "%63[^:]: %lu kB\n", k, &v) == 2) {
        if (!strcmp(k, "MemTotal")) total = v;
        else if (!strcmp(k, "MemAvailable")) avail = v;
        if (total && avail) break;
    }
    fclose(f);
    if (total > 0) {
        int pct = (int)(((total - avail) * 100) / total);
        emit("ram %d", pct);
    }
}

static void poll_disk(void) {
    struct statvfs s;
    if (statvfs("/", &s) != 0) return;
    if (s.f_blocks == 0) return;
    unsigned long long used = (unsigned long long)(s.f_blocks - s.f_bavail);
    int pct = (int)((used * 100) / s.f_blocks);
    emit("disk %d", pct);
}

/* ----------------------------- battery ----------------------------- */

static char bat_dir[384] = "";

static void find_battery(void) {
    DIR *d = opendir("/sys/class/power_supply");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        char path[384];
        snprintf(path, sizeof(path),
                 "/sys/class/power_supply/%s/type", de->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char type[32] = {0};
        if (fgets(type, sizeof(type), f)) {
            type[strcspn(type, "\n")] = 0;
            if (!strcmp(type, "Battery")) {
                snprintf(bat_dir, sizeof(bat_dir),
                         "/sys/class/power_supply/%s", de->d_name);
                fclose(f);
                break;
            }
        }
        fclose(f);
    }
    closedir(d);
}

static int read_int_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int v;
    int r = fscanf(f, "%d", &v);
    fclose(f);
    return r == 1 ? v : -1;
}

static int read_str_file(const char *path, char *out, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    if (!fgets(out, (int)cap, f)) { fclose(f); return -1; }
    fclose(f);
    out[strcspn(out, "\n")] = 0;
    return 0;
}

static void poll_battery(void) {
    if (bat_dir[0] == 0) find_battery();
    if (bat_dir[0] == 0) return;
    char p[400];
    snprintf(p, sizeof(p), "%s/capacity", bat_dir);
    int cap = read_int_file(p);
    snprintf(p, sizeof(p), "%s/status", bat_dir);
    char status[32] = "Unknown";
    read_str_file(p, status, sizeof(status));
    if (cap >= 0) emit("bat %d %s", cap, status);
}

/* ----------------------------- network ----------------------------- */

static void poll_net(void) {
    /* Cheap: scan /proc/net/route for first non-default-iface UP entry,
     * fall back to /sys/class/net dirs. SSID via iwgetid -r if present. */
    char iface[32] = "";
    FILE *r = fopen("/proc/net/route", "r");
    if (r) {
        char line[256];
        if (fgets(line, sizeof(line), r)) {  /* skip header */
            while (fgets(line, sizeof(line), r)) {
                char ifn[32]; unsigned long dest;
                if (sscanf(line, "%31s %lx", ifn, &dest) == 2) {
                    if (dest == 0 && strcmp(ifn, "lo") != 0) {
                        snprintf(iface, sizeof(iface), "%s", ifn);
                        break;
                    }
                }
            }
        }
        fclose(r);
    }
    if (iface[0] == 0) { emit("net none"); return; }

    char ssid[64] = "";
    FILE *p = popen("iwgetid -r 2>/dev/null", "r");
    if (p) {
        if (fgets(ssid, sizeof(ssid), p)) ssid[strcspn(ssid, "\n")] = 0;
        pclose(p);
    }
    if (ssid[0]) emit("net %s %s", iface, ssid);
    else         emit("net %s", iface);
}

/* ----------------------------- volume ----------------------------- */

static int parse_pct(const char *s) {
    /* find "NN%" */
    while (*s) {
        if (isdigit((unsigned char)*s)) {
            int v = 0;
            while (isdigit((unsigned char)*s)) { v = v * 10 + (*s - '0'); s++; }
            if (*s == '%') return v;
        } else s++;
    }
    return -1;
}

static void poll_volume(void) {
    int vol = -1;
    char mute[8] = "no";

    FILE *p = popen("pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null", "r");
    if (p) {
        char line[256];
        if (fgets(line, sizeof(line), p)) vol = parse_pct(line);
        pclose(p);
    }
    p = popen("pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null", "r");
    if (p) {
        char line[64];
        if (fgets(line, sizeof(line), p)) {
            if (strstr(line, "yes")) snprintf(mute, sizeof(mute), "yes");
        }
        pclose(p);
    }
    if (vol >= 0) emit("vol %d %s", vol, mute);
}

/* ----------------------------- netlink ----------------------------- */

static int open_netlink(void) {
    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC,
                    NETLINK_KOBJECT_UEVENT);
    if (fd < 0) return -1;
    struct sockaddr_nl sa = {0};
    sa.nl_family = AF_NETLINK;
    sa.nl_pid = (unsigned)getpid();
    sa.nl_groups = 1;  /* uevent group */
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void handle_netlink(int fd) {
    char buf[BUF];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, MSG_DONTWAIT);
    if (n <= 0) return;
    buf[n] = 0;

    /* uevent: header line then NUL-separated KEY=VALUE entries */
    int is_power = 0, is_net = 0;
    char *p = buf;
    char *end = buf + n;
    while (p < end) {
        size_t len = strnlen(p, (size_t)(end - p));
        if (!strncmp(p, "SUBSYSTEM=power_supply", 22)) is_power = 1;
        else if (!strncmp(p, "SUBSYSTEM=net", 13))    is_net = 1;
        p += len + 1;
        if (len == 0) break;
    }
    if (is_power) poll_battery();
    if (is_net)   poll_net();
}

/* ----------------------------- pactl child ----------------------------- */

static pid_t pactl_pid = -1;
static int pactl_fd = -1;

static int spawn_pactl(void) {
    int pipefd[2];
    if (pipe(pipefd) < 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (pid == 0) {
        /* child */
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[0]);
        close(pipefd[1]);
        execlp("pactl", "pactl", "subscribe", (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
    pactl_pid = pid;
    pactl_fd = pipefd[0];
    return 0;
}

static void handle_pactl(void) {
    char buf[BUF];
    ssize_t n = read(pactl_fd, buf, sizeof(buf) - 1);
    if (n <= 0) {
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
            close(pactl_fd);
            pactl_fd = -1;
            if (pactl_pid > 0) { kill(pactl_pid, SIGTERM); pactl_pid = -1; }
        }
        return;
    }
    buf[n] = 0;
    /* coalesce multiple sink events into one query */
    if (strstr(buf, "on sink")) poll_volume();
}

/* ----------------------------- main ----------------------------- */

static void on_sig(int s) { (void)s; want_exit = 1; }

int main(int argc, char **argv) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    if (argc >= 2) {
        snprintf(fifo_path, sizeof(fifo_path), "%s", argv[1]);
    } else {
        snprintf(fifo_path, sizeof(fifo_path), "%s/qs-stats.pipe", tmp);
    }

    /* idempotent FIFO create */
    if (mkfifo(fifo_path, 0644) < 0 && errno != EEXIST) {
        fprintf(stderr, "qs-stats-daemon: mkfifo %s: %s\n",
                fifo_path, strerror(errno));
        return 1;
    }
    open_fifo();

    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_sig);
    signal(SIGINT,  on_sig);
    signal(SIGCHLD, SIG_IGN);  /* reap pactl auto */

    int nl_fd = open_netlink();
    if (nl_fd < 0) {
        fprintf(stderr, "qs-stats-daemon: netlink open failed (%s); "
                "falling back to slow poll for bat/net\n",
                strerror(errno));
    }

    int tfd_fast = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    int tfd_slow = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    /* fallback timer for bat+net when netlink unavailable; otherwise unused */
    int tfd_fallback = -1;
    struct itimerspec fast = {0};
    fast.it_value.tv_sec = 1;       /* first fire in 1s */
    fast.it_interval.tv_sec = 10;   /* repeat every 10s */
    struct itimerspec slow = {0};
    slow.it_value.tv_sec = 2;
    slow.it_interval.tv_sec = 60;
    timerfd_settime(tfd_fast, 0, &fast, NULL);
    timerfd_settime(tfd_slow, 0, &slow, NULL);
    if (nl_fd < 0) {
        tfd_fallback = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
        struct itimerspec fb = {0};
        fb.it_value.tv_sec = 3;
        fb.it_interval.tv_sec = 30;
        timerfd_settime(tfd_fallback, 0, &fb, NULL);
    }

    spawn_pactl();

    /* initial state burst (vol+net+bat fire on first events; force here) */
    poll_battery();
    poll_net();
    poll_volume();
    poll_disk();

    while (!want_exit) {
        struct pollfd pfds[5];
        int nf = 0;
        if (nl_fd >= 0)        { pfds[nf].fd = nl_fd;        pfds[nf].events = POLLIN; nf++; }
        if (tfd_fast >= 0)     { pfds[nf].fd = tfd_fast;     pfds[nf].events = POLLIN; nf++; }
        if (tfd_slow >= 0)     { pfds[nf].fd = tfd_slow;     pfds[nf].events = POLLIN; nf++; }
        if (tfd_fallback >= 0) { pfds[nf].fd = tfd_fallback; pfds[nf].events = POLLIN; nf++; }
        if (pactl_fd >= 0)     { pfds[nf].fd = pactl_fd;     pfds[nf].events = POLLIN; nf++; }

        int r = poll(pfds, (nfds_t)nf, 30000);
        if (r < 0) { if (errno == EINTR) continue; break; }
        if (r == 0) {
            /* idle tick: try to revive pactl if it died */
            if (pactl_fd < 0) spawn_pactl();
            continue;
        }
        for (int k = 0; k < nf; k++) {
            if (!(pfds[k].revents & POLLIN)) continue;
            int fd = pfds[k].fd;
            if (fd == nl_fd) {
                handle_netlink(nl_fd);
            } else if (fd == tfd_fast) {
                uint64_t exp; (void)read(tfd_fast, &exp, sizeof(exp));
                poll_cpu();
                poll_ram();
            } else if (fd == tfd_slow) {
                uint64_t exp; (void)read(tfd_slow, &exp, sizeof(exp));
                poll_disk();
            } else if (fd == tfd_fallback) {
                uint64_t exp; (void)read(tfd_fallback, &exp, sizeof(exp));
                poll_battery();
                poll_net();
            } else if (fd == pactl_fd) {
                handle_pactl();
            }
        }
        if (pactl_fd < 0) spawn_pactl();
    }

    if (pactl_pid > 0) kill(pactl_pid, SIGTERM);
    if (fifo_fd >= 0) close(fifo_fd);
    return 0;
}
