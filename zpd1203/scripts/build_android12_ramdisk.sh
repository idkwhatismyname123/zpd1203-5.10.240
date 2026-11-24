#!/usr/bin/env bash
# Build clean Android 12 ramdisk for Phase B-2 testing on slot b (while super only has *_a).
# Input:  $ROOT/extracted/boot/ramdisk (stock boot_a ramdisk)
# Output: $ROOT/out/ramdisk-android12-b2.cpio.gz
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STOCK_RD="${STOCK_RD:-$ROOT/extracted/boot/ramdisk}"
OUT_RD="${OUT_RD:-$ROOT/out/ramdisk-android12-b2.cpio.gz}"
RADIO_MODULE_DIR="${RADIO_MODULE_DIR:-}"
WORK="/tmp/a12_ramdisk_work"
FAKEROUT_ENV="/tmp/a12_ramdisk.fakeroot"
MAX_RD_BYTES=16252928 # 15.5 MiB safe ceiling inside 32 MiB boot_b (Kernel ~15.4 MiB)

if [ ! -f "$STOCK_RD" ]; then
  echo "ERROR: stock ramdisk not found: $STOCK_RD" >&2
  exit 1
fi

rm -rf "$WORK" "$FAKEROUT_ENV"
mkdir -p "$WORK"

echo "=== 1. Unpacking stock boot_a ramdisk via fakeroot ==="
fakeroot -s "$FAKEROUT_ENV" bash -c "cd '$WORK' && gzip -dc '$STOCK_RD' | cpio -idmu --no-absolute-filenames"

echo "=== 2. Removing Magisk overlays & installing static pre-init COM18+ADB wrapper ==="
[ -d "$WORK/.backup" ] && chmod -R u+rwX "$WORK/.backup" || true
rm -rf "$WORK/.backup" "$WORK/overlay.d" "$WORK/init"

cat > /tmp/a12_init_wrapper.c <<'EOF'
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <termios.h>
#include <unistd.h>

static int write_sys(const char *path, const char *val) {
    int fd = open(path, O_WRONLY | O_TRUNC);
    if (fd < 0) return -1;
    ssize_t n = write(fd, val, strlen(val));
    close(fd);
    return n < 0 ? -1 : 0;
}

static void klog_note(const char *msg) {
    int fd = open("/dev/kmsg", O_WRONLY);
    if (fd >= 0) {
        (void)!write(fd, msg, strlen(msg));
        close(fd);
    }
}

#ifdef ZPD_WIRELESS_MODULES
#define RADIO_ARCHIVE_DIR "/zpd-wireless/"
#define RADIO_STAGE_DIR "/dev/.zpd-wireless/"
#define RADIO_VENDOR_DIR "/vendor/lib/modules/"

static struct {
    const char *file;
    int replace_vendor;
    int load_at_boot;
    int fd;
} radio_modules[] = {
    { "btif_drv.ko",         0, 1, -1 },
    { "conn_md_drv.ko",      0, 1, -1 },
    { "connadp.ko",          0, 1, -1 },
    { "cfg80211.ko",         0, 1, -1 },
    { "connfem.ko",          1, 1, -1 },
    { "wmt_drv.ko",          1, 1, -1 },
    { "bt_drv_connac1x.ko",  1, 0, -1 },
    { "wmt_chrdev_wifi.ko",  1, 0, -1 },
    { "wlan_drv_gen4m.ko",   1, 0, -1 },
};

#define RADIO_MODULE_COUNT (sizeof(radio_modules) / sizeof(radio_modules[0]))

static void radio_error(const char *action, const char *file) {
    char message[256];
    snprintf(message, sizeof(message), "<3>a12-wrap: wireless %s %s: %s\n",
             action, file, strerror(errno));
    klog_note(message);
}

static void close_radio_modules(void) {
    for (size_t i = 0; i < RADIO_MODULE_COUNT; i++) {
        if (radio_modules[i].fd >= 0)
            close(radio_modules[i].fd);
        radio_modules[i].fd = -1;
    }
}

/* First-stage init deletes the old root during SwitchRoot. Keep these files open. */
static void open_radio_modules(void) {
    for (size_t i = 0; i < RADIO_MODULE_COUNT; i++) {
        char path[96];
        snprintf(path, sizeof(path), "%s%s", RADIO_ARCHIVE_DIR, radio_modules[i].file);
        radio_modules[i].fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (radio_modules[i].fd < 0) {
            radio_error("open", path);
            close_radio_modules();
            return;
        }
    }
}

static int stage_radio_module(int source, const char *path) {
    int dest = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (dest < 0)
        return -1;

    char buffer[16384];
    for (;;) {
        ssize_t count = read(source, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR)
            continue;
        if (count < 0)
            break;
        if (count == 0)
            return close(dest);

        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(dest, buffer + offset, count - offset);
            if (written < 0 && errno == EINTR)
                continue;
            if (written <= 0) {
                if (written == 0)
                    errno = EIO;
                goto copy_failed;
            }
            offset += written;
        }
    }

copy_failed:
    {
        int error = errno;
        close(dest);
        errno = error;
        return -1;
    }
}

static void setup_wireless(void) {
    char path[96], target[96];
    size_t staged = 0, bound = 0;

    if (radio_modules[0].fd < 0)
        return;
    if (mkdir(RADIO_STAGE_DIR, 0700) < 0) {
        radio_error("mkdir", RADIO_STAGE_DIR);
        goto done;
    }

    for (size_t i = 0; i < RADIO_MODULE_COUNT; i++) {
        if (!radio_modules[i].replace_vendor)
            continue;
        snprintf(path, sizeof(path), "%s%s", RADIO_STAGE_DIR, radio_modules[i].file);
        staged = i + 1;
        if (stage_radio_module(radio_modules[i].fd, path) < 0) {
            radio_error("stage", path);
            goto rollback;
        }
    }

    for (size_t i = 0; i < RADIO_MODULE_COUNT; i++) {
        if (!radio_modules[i].replace_vendor)
            continue;
        snprintf(path, sizeof(path), "%s%s", RADIO_STAGE_DIR, radio_modules[i].file);
        snprintf(target, sizeof(target), "%s%s", RADIO_VENDOR_DIR, radio_modules[i].file);
        if (mount(path, target, NULL, MS_BIND, NULL) < 0) {
            radio_error("bind", target);
            goto rollback;
        }
        bound = i + 1;
    }

    /* Keep the vendor Bluetooth and WLAN readiness triggers. */
    for (size_t i = 0; i < RADIO_MODULE_COUNT; i++) {
        if (!radio_modules[i].load_at_boot)
            continue;
        const char *file = radio_modules[i].file;
        if (syscall(SYS_finit_module, radio_modules[i].fd, "", 0) < 0 && errno != EEXIST) {
            radio_error("load", file);
            goto done;
        }
        char message[128];
        snprintf(message, sizeof(message), "<6>a12-wrap: wireless loaded %s\n", file);
        klog_note(message);
    }
    klog_note("<6>a12-wrap: wireless modules staged for vendor init\n");
    goto done;

rollback:
    for (size_t i = 0; i < bound; i++) {
        if (radio_modules[i].replace_vendor) {
            snprintf(target, sizeof(target), "%s%s", RADIO_VENDOR_DIR, radio_modules[i].file);
            if (umount2(target, MNT_DETACH) < 0)
                radio_error("rollback", target);
        }
    }
    for (size_t i = 0; i < staged; i++) {
        if (radio_modules[i].replace_vendor) {
            snprintf(path, sizeof(path), "%s%s", RADIO_STAGE_DIR, radio_modules[i].file);
            unlink(path);
        }
    }
    rmdir(RADIO_STAGE_DIR);
done:
    close_radio_modules();
}
#endif

static int read_sys_str(const char *path, char *buf, size_t sz) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sz - 1);
    close(fd);
    if (n <= 0) {
        buf[0] = '\0';
        return -1;
    }
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) {
        buf[--n] = '\0';
    }
    return 0;
}

static int find_hw_udc(char *udc, size_t sz, int retries) {
    udc[0] = '\0';
    for (int attempt = 0; attempt < retries && !udc[0]; attempt++) {
        DIR *d = opendir("/sys/class/udc");
        if (d) {
            struct dirent *de;
            while ((de = readdir(d)) != NULL) {
                if (de->d_name[0] == '.') continue;
                if (strncmp(de->d_name, "dummy_udc", 9) == 0) continue;
                snprintf(udc, sz, "%s", de->d_name);
                break;
            }
            closedir(d);
        }
        if (!udc[0] && attempt + 1 < retries) usleep(200000);
    }
    return udc[0] ? 0 : -1;
}

static int open_tty_raw(const char *devpath) {
    int fd = open(devpath, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd >= 0) {
        struct termios tio;
        if (tcgetattr(fd, &tio) == 0) {
            cfmakeraw(&tio);
            tcsetattr(fd, TCSANOW, &tio);
        }
    }
    return fd;
}

static void setup_hwc_fb_fallback(int *hwc_bound, int *bridge_fd) {
    char msg[256];
    int lfd = open("/dev/.fb0_bridge.log", O_CREAT | O_WRONLY | O_TRUNC, 0666);
    if (lfd >= 0) close(lfd);
    chmod("/dev/.fb0_bridge.log", 0666);
    int efd = open("/dev/.empty_hwc", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (efd >= 0) close(efd);
    chmod("/dev/.empty_hwc", 0644);
    if (mount("/dev/.empty_hwc", "/vendor/lib64/hw/hwcomposer.mt6768.so",
              "none", MS_BIND, NULL) == 0) {
        *hwc_bound = 1;
        klog_note("<6>a12-wrap: bind-mounted /dev/.empty_hwc over hwcomposer.mt6768.so (HWC2OnFbAdapter enabled)\n");
    } else {
        snprintf(msg, sizeof(msg),
                 "<4>a12-wrap: bind-mount hwcomposer.mt6768.so failed errno=%d (%s)\n",
                 errno, strerror(errno));
        klog_note(msg);
    }

    if (bridge_fd && *bridge_fd >= 0) {
        int dfd = open("/dev/.gralloc_fb0_bridge.so", O_CREAT | O_WRONLY | O_TRUNC, 0755);
        size_t total = 0;
        int copy_ok = (dfd >= 0);
        if (dfd >= 0) {
            char buf[4096];
            lseek(*bridge_fd, 0, SEEK_SET);
            for (;;) {
                ssize_t r = read(*bridge_fd, buf, sizeof(buf));
                if (r == 0) break;
                if (r < 0) {
                    if (errno == EINTR) continue;
                    copy_ok = 0;
                    break;
                }
                size_t off = 0;
                while (off < (size_t)r) {
                    ssize_t w = write(dfd, buf + off, (size_t)r - off);
                    if (w <= 0) {
                        if (w < 0 && errno == EINTR) continue;
                        copy_ok = 0;
                        break;
                    }
                    off += (size_t)w;
                }
                if (!copy_ok) break;
                total += (size_t)r;
            }
            close(dfd);
        }
        close(*bridge_fd);
        *bridge_fd = -1;

        if (copy_ok && total > 0) {
            chmod("/dev/.gralloc_fb0_bridge.so", 0755);
            if (mount("/dev/.gralloc_fb0_bridge.so", "/vendor/lib64/hw/gralloc.default.so",
                      "none", MS_BIND, NULL) == 0) {
                snprintf(msg, sizeof(msg),
                         "<6>a12-wrap: bind-mounted /dev/.gralloc_fb0_bridge.so over gralloc.default.so (%zu bytes)\n",
                         total);
                klog_note(msg);
            } else {
                snprintf(msg, sizeof(msg),
                         "<4>a12-wrap: bind-mount gralloc.default.so failed errno=%d (%s)\n",
                         errno, strerror(errno));
                klog_note(msg);
            }
        } else {
            snprintf(msg, sizeof(msg),
                     "<4>a12-wrap: copy gralloc.fb0_bridge.so failed errno=%d (%s)\n",
                     errno, strerror(errno));
            klog_note(msg);
        }
    }
}

static int bind_composite_g1(int *tty_fd, const char *hw_udc, int with_adb) {
    char note[512];
    char udc[256];
    snprintf(udc, sizeof(udc), "%s", hw_udc);
    if (!udc[0]) find_hw_udc(udc, sizeof(udc), 5);
    if (!udc[0]) snprintf(udc, sizeof(udc), "musb-hdrc");

    write_sys("/config/usb_gadget/g1/os_desc/use", "0\n");
    if (with_adb) {
        write_sys("/config/usb_gadget/g1/bDeviceClass", "0xef\n");
        write_sys("/config/usb_gadget/g1/bDeviceSubClass", "0x02\n");
        write_sys("/config/usb_gadget/g1/bDeviceProtocol", "0x01\n");
        write_sys("/config/usb_gadget/g1/idVendor", "0x0e8d\n");
        write_sys("/config/usb_gadget/g1/idProduct", "0x2006\n");
        write_sys("/config/usb_gadget/g1/configs/b.1/strings/0x409/configuration", "adb_acm\n");
    } else {
        write_sys("/config/usb_gadget/g1/bDeviceClass", "0x02\n");
        write_sys("/config/usb_gadget/g1/bDeviceSubClass", "0x00\n");
        write_sys("/config/usb_gadget/g1/bDeviceProtocol", "0x00\n");
        write_sys("/config/usb_gadget/g1/idVendor", "0x1d6b\n");
        write_sys("/config/usb_gadget/g1/idProduct", "0x0104\n");
        write_sys("/config/usb_gadget/g1/configs/b.1/strings/0x409/configuration", "acm_only\n");
    }

    const char *old_links[] = {
        "/config/usb_gadget/g1/configs/b.1/f0",
        "/config/usb_gadget/g1/configs/b.1/f1",
        "/config/usb_gadget/g1/configs/b.1/f2",
        "/config/usb_gadget/g1/configs/b.1/f3",
        "/config/usb_gadget/g1/configs/b.1/f4",
        "/config/usb_gadget/g1/configs/b.1/f5",
    };
    for (size_t i = 0; i < sizeof(old_links) / sizeof(old_links[0]); i++) {
        unlink(old_links[i]);
    }

    mkdir("/config/usb_gadget/g1/functions/acm.gs1", 0755);
    if (with_adb) {
        mkdir("/config/usb_gadget/g1/functions/ffs.adb", 0755);
        if (symlink("/config/usb_gadget/g1/functions/ffs.adb",
                    "/config/usb_gadget/g1/configs/b.1/f1") < 0 && errno != EEXIST) {
            snprintf(note, sizeof(note), "<4>a12-wrap: symlink g1/f1 ffs.adb failed errno=%d (%s)\n",
                     errno, strerror(errno));
            klog_note(note);
        }
        if (symlink("/config/usb_gadget/g1/functions/acm.gs1",
                    "/config/usb_gadget/g1/configs/b.1/f2") < 0 && errno != EEXIST) {
            snprintf(note, sizeof(note), "<4>a12-wrap: symlink g1/f2 acm.gs1 failed errno=%d (%s)\n",
                     errno, strerror(errno));
            klog_note(note);
        }
    } else {
        if (symlink("/config/usb_gadget/g1/functions/acm.gs1",
                    "/config/usb_gadget/g1/configs/b.1/f1") < 0 && errno != EEXIST) {
            snprintf(note, sizeof(note), "<4>a12-wrap: symlink g1/f1 acm.gs1 failed errno=%d (%s)\n",
                     errno, strerror(errno));
            klog_note(note);
        }
    }

    char udc_nl[280];
    snprintf(udc_nl, sizeof(udc_nl), "%s\n", udc);
    int bound = -1;
    int last_err = 0;
    for (int i = 0; i < 5; i++) {
        if (write_sys("/config/usb_gadget/g1/UDC", udc_nl) == 0) {
            bound = 0;
            break;
        }
        last_err = errno;
        usleep(100000);
    }

    if (bound == 0) {
        snprintf(note, sizeof(note),
                 "<6>a12-wrap: first-bind g1 (%s) to %s ok\n",
                 with_adb ? "ffs.adb+acm.gs1" : "acm.gs1-fallback", udc);
        klog_note(note);
    } else {
        snprintf(note, sizeof(note),
                 "<3>a12-wrap: bind g1/UDC (%s) failed errno=%d (%s)\n",
                 udc, last_err, strerror(last_err));
        klog_note(note);
        return -1;
    }

    char pbuf[32] = {0};
    int port_num = 1;
    if (read_sys_str("/config/usb_gadget/g1/functions/acm.gs1/port_num", pbuf, sizeof(pbuf)) == 0) {
        port_num = atoi(pbuf);
    }
    char tty_path[64];
    snprintf(tty_path, sizeof(tty_path), "/dev/ttyGS%d", port_num);

    int new_tty = open_tty_raw(tty_path);
    if (new_tty >= 0) {
        if (*tty_fd >= 0) close(*tty_fd);
        *tty_fd = new_tty;
        snprintf(note, sizeof(note),
                 "<6>a12-wrap: COM logger attached to %s (%s)\n",
                 tty_path, with_adb ? "composite ADB+ACM" : "ACM fallback");
        klog_note(note);
    } else {
        snprintf(note, sizeof(note),
                 "<4>a12-wrap: open %s failed errno=%d (%s)\n",
                 tty_path, errno, strerror(errno));
        klog_note(note);
    }
    return 0;
}

static void run_logger_child(int kmsg_fd, int proc_fd, int bridge_fd, const char *hw_udc) {
    static char ring[524288];
    size_t fill = 0, sent = 0;
    char cmd[64];
    size_t clen = 0;
    int tty_fd = -1;
    int released = 0;
    int in_new_root = 0;
    int hwc_bound = 0;
    int fb_chmed = 0;
    int switched_to_g1 = 0;
    int loops = 0;

    setsid();
    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);

    static const char banner[] =
        "\r\n=== A12 Single-Bind Logger active (Option A + g1 ADB/ACM; commands: status, unbind, reboot-fb) ===\r\n";
    memcpy(ring, banner, sizeof(banner) - 1);
    fill = sizeof(banner) - 1;

    while (!released) {
        /* 1. Drain new lines from /dev/kmsg without blocking */
        if (kmsg_fd >= 0) {
            for (int iter = 0; iter < 64; iter++) {
                char kline[2048];
                ssize_t kr = read(kmsg_fd, kline, sizeof(kline) - 1);
                if (kr <= 0) break;
                for (ssize_t i = 0; i < kr; i++) {
                    char c = kline[i];
                    if (fill + 2 >= sizeof(ring)) {
                        if (sent > 0) {
                            size_t rem = fill - sent;
                            memmove(ring, ring + sent, rem);
                            fill = rem;
                            sent = 0;
                        }
                        if (fill + 2 >= sizeof(ring)) {
                            size_t drop = sizeof(ring) / 4;
                            memmove(ring, ring + drop, fill - drop);
                            fill -= drop;
                            sent = (sent > drop) ? (sent - drop) : 0;
                        }
                    }
                    if (c == '\n') {
                        ring[fill++] = '\r';
                        ring[fill++] = '\n';
                    } else {
                        ring[fill++] = c;
                    }
                }
            }
        }

        /* 2. Flush buffered bytes once g1 ttyGS* is open */
        if (tty_fd >= 0 && sent < fill) {
            while (sent < fill) {
                size_t chunk = fill - sent;
                if (chunk > 512) chunk = 512;
                ssize_t w = write(tty_fd, ring + sent, chunk);
                if (w > 0) {
                    sent += (size_t)w;
                    continue;
                }
                break;
            }
            if (sent == fill) {
                sent = 0;
                fill = 0;
            }
        }

        /* 3. Poll ttyGS* for commands (50ms slice) */
        if (tty_fd >= 0) {
            struct pollfd pfd;
            pfd.fd = tty_fd;
            pfd.events = POLLIN;
            int pr = poll(&pfd, 1, 50);
            if (pr > 0 && (pfd.revents & POLLIN)) {
                char rb[64];
                ssize_t nr = read(tty_fd, rb, sizeof(rb));
                if (nr > 0) {
                    for (ssize_t i = 0; i < nr; i++) {
                        char c = rb[i];
                        if (c == '\r' || c == '\n') {
                            cmd[clen] = '\0';
                            if (strcmp(cmd, "reboot-fb") == 0) {
                                const char *m = "\r\nRebooting to fastboot...\r\n";
                                (void)!write(tty_fd, m, strlen(m));
                                sync();
                                syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                                        LINUX_REBOOT_CMD_RESTART2, "bootloader");
                            } else if (strcmp(cmd, "unbind") == 0) {
                                const char *m = "\r\nReleasing active UDC...\r\n";
                                (void)!write(tty_fd, m, strlen(m));
                                released = 1;
                            } else if (strcmp(cmd, "status") == 0) {
                                char udc_cur[128] = "n/a";
                                char sbuf[320];
                                read_sys_str("/config/usb_gadget/g1/UDC", udc_cur, sizeof(udc_cur));
                                int n = snprintf(
                                    sbuf, sizeof(sbuf),
                                    "\r\n[status] new_root=%d hwc_bound=%d g1_switched=%d ep1=%d fb0=%d g1_UDC='%s'\r\n",
                                    in_new_root, hwc_bound, switched_to_g1,
                                    access("/dev/usb-ffs/adb/ep1", F_OK) == 0,
                                    access("/dev/graphics/fb0", F_OK) == 0,
                                    udc_cur);
                                if (n > 0) (void)!write(tty_fd, sbuf, (size_t)n);
                            }
                            clen = 0;
                        } else if ((unsigned char)c >= 0x20 && (unsigned char)c < 0x7f) {
                            if (clen + 1 < sizeof(cmd)) cmd[clen++] = c;
                        }
                    }
                }
            }
        } else {
            usleep(50000);
        }
        loops++;

        /* 4. Enter live Android root once SwitchRoot completes & enable Option A HWC fallback */
        if (!in_new_root && proc_fd >= 0 &&
            faccessat(proc_fd, "1/root/vendor/lib64/hw/hwcomposer.mt6768.so", F_OK, 0) == 0) {
            int rfd = openat(proc_fd, "1/root", O_RDONLY | O_DIRECTORY);
            if (rfd >= 0) {
                if (fchdir(rfd) == 0 && chroot(".") == 0 && chdir("/") == 0) {
                    in_new_root = 1;
                    klog_note("<6>a12-wrap: entered live Android root after SwitchRoot\n");
                    setup_hwc_fb_fallback(&hwc_bound, &bridge_fd);
#ifdef ZPD_WIRELESS_MODULES
                    setup_wireless();
#endif
                }
                close(rfd);
            }
        }

        /* 5. Ensure /dev/graphics/fb0 is accessible once created */
        if (in_new_root && !fb_chmed && access("/dev/graphics/fb0", F_OK) == 0) {
            chmod("/dev/graphics/fb0", 0666);
            fb_chmed = 1;
            klog_note("<6>a12-wrap: chmod 0666 /dev/graphics/fb0 ok\n");
        }

        /* 6. Bind g1 (ffs.adb + acm.gs1) ONCE when adbd FunctionFS ep1 is ready, or fallback at ~175s */
        if (in_new_root && !switched_to_g1 &&
            access("/config/usb_gadget/g1/configs/b.1", F_OK) == 0) {
            if (access("/dev/usb-ffs/adb/ep1", F_OK) == 0) {
                if (bind_composite_g1(&tty_fd, hw_udc, 1) == 0) {
                    switched_to_g1 = 1;
                }
            } else if (loops >= 3500) {
                klog_note("<4>a12-wrap: ep1 timeout at ~175s, binding ACM-only fallback on g1\n");
                if (bind_composite_g1(&tty_fd, hw_udc, 0) == 0) {
                    switched_to_g1 = 1;
                }
            }
        }
    }

    if (switched_to_g1) {
        write_sys("/config/usb_gadget/g1/UDC", "\n");
    }
    if (bridge_fd >= 0) close(bridge_fd);
    if (proc_fd >= 0) close(proc_fd);
    if (tty_fd >= 0) close(tty_fd);
    if (kmsg_fd >= 0) close(kmsg_fd);
    _exit(0);
}

int main(int argc, char **argv) {
    struct stat st;
    int mounted_dev = 0;
    if (stat("/dev/kmsg", &st) != 0) {
        if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) == 0) mounted_dev = 1;
    }
    int mounted_sys = (mount("sysfs", "/sys", "sysfs", 0, NULL) == 0);
    mkdir("/proc", 0755);
    int mounted_proc = (mount("proc", "/proc", "proc", 0, NULL) == 0);
    int proc_fd = open("/proc", O_RDONLY | O_DIRECTORY);

    char hw_udc[256] = {0};
    if (find_hw_udc(hw_udc, sizeof(hw_udc), 25) < 0) {
        klog_note("<4>a12-wrap: no hardware UDC found early; will retry musb-hdrc\n");
    } else {
        char note[320];
        snprintf(note, sizeof(note), "<6>a12-wrap: detected hw UDC %s (deferring first bind to g1)\n", hw_udc);
        klog_note(note);
    }

    int bridge_fd = open("/gralloc.fb0_bridge.so", O_RDONLY);
    if (bridge_fd < 0) {
        klog_note("<4>a12-wrap: warning: open /gralloc.fb0_bridge.so failed\n");
    }

    int kmsg_fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
#ifdef ZPD_WIRELESS_MODULES
    open_radio_modules();
#endif
    if (kmsg_fd >= 0 || proc_fd >= 0) {
        pid_t pid = fork();
        if (pid == 0) {
            run_logger_child(kmsg_fd, proc_fd, bridge_fd, hw_udc);
        }
        usleep(50000);
    }

#ifdef ZPD_WIRELESS_MODULES
    close_radio_modules();
#endif
    if (bridge_fd >= 0) close(bridge_fd);
    if (kmsg_fd >= 0) close(kmsg_fd);
    if (proc_fd >= 0) close(proc_fd);

    /* Unmount temp mounts lazily so Android first_stage_init mounts them cleanly */
    if (mounted_sys) umount2("/sys", MNT_DETACH);
    if (mounted_dev) umount2("/dev", MNT_DETACH);
    if (mounted_proc) umount2("/proc", MNT_DETACH);

    klog_note("<6>a12-wrap: execv(/system/bin/init)\n");
    (void)argc;
    execv("/system/bin/init", argv);
    klog_note("<3>a12-wrap: execv(/system/bin/init) FAILED!\n");
    for (;;) sleep(1);
    return 1;
}
EOF

wrapper_flags=()
if [[ -n "$RADIO_MODULE_DIR" ]]; then
  wrapper_flags+=(-DZPD_WIRELESS_MODULES)
fi
aarch64-linux-gnu-gcc -static -O2 -s -Wall -Wextra -Werror "${wrapper_flags[@]}" \
  -o "$WORK/init" /tmp/a12_init_wrapper.c
rm -f /tmp/a12_init_wrapper.c
chmod 0750 "$WORK/init"

BRIDGE_SRC="$ROOT/tools/gralloc_fb0_bridge.c"
if [ ! -f "$BRIDGE_SRC" ]; then
  echo "ERROR: missing $BRIDGE_SRC" >&2
  exit 1
fi
aarch64-linux-gnu-gcc -shared -fPIC -nostdlib -ffreestanding -fno-builtin -fno-stack-protector \
  -O2 -s -Wall -Wextra -Werror -Wl,-soname,gralloc.default.so -Wl,--hash-style=both \
  -o "$WORK/gralloc.fb0_bridge.so" "$BRIDGE_SRC"
chmod 0755 "$WORK/gralloc.fb0_bridge.so"
if aarch64-linux-gnu-readelf -d "$WORK/gralloc.fb0_bridge.so" | grep -q "NEEDED"; then
  echo "ERROR: gralloc.fb0_bridge.so must have zero NEEDED dependencies" >&2
  exit 1
fi
if ! aarch64-linux-gnu-readelf --dyn-syms "$WORK/gralloc.fb0_bridge.so" | grep -Eq "[[:space:]]HMI([[:space:]]|$)"; then
  echo "ERROR: gralloc.fb0_bridge.so missing exported HMI symbol" >&2
  exit 1
fi

echo "=== 3. Keeping stock first_stage_ramdisk/fstab.mt6768 intact (slot_a forced via kernel cmdline) ==="
FSTAB="$WORK/first_stage_ramdisk/fstab.mt6768"
if [ ! -f "$FSTAB" ]; then
  echo "ERROR: missing $FSTAB" >&2
  exit 1
fi
grep -E "^(system|vendor|product)" "$FSTAB" || true

echo "=== 4. Patching prop.default for early root ADB & permissive bring-up ==="
PROP="$WORK/prop.default"
if [ ! -f "$PROP" ]; then
  echo "ERROR: missing $PROP" >&2
  exit 1
fi

python3 - "$PROP" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
lines = p.read_text(encoding="utf-8").splitlines()
overrides = {
    "ro.debuggable": "1",
    "ro.adb.secure": "0",
    "persist.sys.usb.config": "adb",
    "ro.vendor.usb.kpoc_adb": "1",
    "service.adb.root": "1",
    "ro.boot.selinux": "permissive",
}
seen = set()
out = []
for ln in lines:
    if ln.startswith("#") or "=" not in ln:
        out.append(ln)
        continue
    k, _ = ln.split("=", 1)
    k = k.strip()
    if k in overrides:
        if k not in seen:
            out.append(f"{k}={overrides[k]}")
            seen.add(k)
        # drop duplicate definitions cleanly
        continue
    out.append(ln)

for k, v in overrides.items():
    if k not in seen:
        out.append(f"{k}={v}")

p.write_text("\n".join(out) + "\n", encoding="utf-8")
print("Patched prop.default keys:", sorted(overrides))
PY

pack_ramdisk() {
  fakeroot -i "$FAKEROUT_ENV" bash -c "cd '$WORK' && find . | LC_ALL=C sort | cpio -o -H newc --reproducible 2>/dev/null | gzip -9 > '$OUT_RD'"
}

echo "=== 5. Packing compressed Android 12 ramdisk ==="
pack_ramdisk
RD_SIZE=$(stat -c %s "$OUT_RD")
echo "Initial packed ramdisk size: $RD_SIZE bytes"

if [ "$RD_SIZE" -gt "$MAX_RD_BYTES" ]; then
  echo "Ramdisk ($RD_SIZE B) > budget ($MAX_RD_BYTES B); stripping res/images/*.png..."
  rm -f "$WORK"/res/images/*.png || true
  pack_ramdisk
  RD_SIZE=$(stat -c %s "$OUT_RD")
  echo "Stripped packed ramdisk size: $RD_SIZE bytes"
  if [ "$RD_SIZE" -gt "$MAX_RD_BYTES" ]; then
    echo "ERROR: ramdisk still exceeds budget ($RD_SIZE > $MAX_RD_BYTES)" >&2
    exit 1
  fi
fi

if [[ -n "$RADIO_MODULE_DIR" ]]; then
  radio_archive="$(mktemp -d)"
  trap 'rm -rf -- "$radio_archive"' EXIT
  mkdir "$radio_archive/zpd-wireless"
  for module in btif_drv conn_md_drv connadp cfg80211 connfem wmt_drv \
                bt_drv_connac1x wmt_chrdev_wifi wlan_drv_gen4m; do
    llvm-strip --strip-unneeded -o "$radio_archive/zpd-wireless/$module.ko" \
      "$RADIO_MODULE_DIR/$module.ko"
  done
  (
    cd "$radio_archive"
    find zpd-wireless | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --reproducible \
      | xz --check=crc32 --lzma2=dict=4MiB > wireless.cpio.xz
  )
  padding=$(( (4 - RD_SIZE % 4) % 4 ))
  head -c "$padding" /dev/zero >> "$OUT_RD"
  cat "$radio_archive/wireless.cpio.xz" >> "$OUT_RD"
  echo "Appended wireless XZ member ($(stat -c %s "$radio_archive/wireless.cpio.xz") bytes)"
fi

chmod -R u+rwX "$WORK" 2>/dev/null || true
rm -rf "$WORK" "$FAKEROUT_ENV"
ls -lh "$OUT_RD"
sha256sum "$OUT_RD"
