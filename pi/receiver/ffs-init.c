/*
 * ffs-init: write FunctionFS descriptors for a minimal vendor-class bulk-OUT
 * interface and keep ep0 open. Also binds the UDC so the gadget enumerates.
 *
 * Stage 1 proof-of-concept: after the usb-gadget-setup.sh script creates the
 * composite (ECM + FFS function) but leaves the UDC unbound, this program
 * writes descriptors, binds UDC, then just echoes any bytes it reads off ep1
 * to stdout so we can verify host-to-device bulk transfer actually works.
 *
 * Build:
 *   gcc -O2 -Wall -o ffs-init ffs-init.c
 */
#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>

#include <linux/usb/ch9.h>
#include <linux/usb/functionfs.h>

#define FFS_MOUNT "/dev/ffs/pidisplay"

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int s) { (void)s; g_stop = 1; }

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, ": %s\n", strerror(errno));
    exit(1);
}

static void info(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void info(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

#pragma pack(push, 1)
struct full_descs {
    struct usb_functionfs_descs_head_v2 header;
    __le32 fs_count;
    __le32 hs_count;
    struct {
        struct usb_interface_descriptor intf;
        struct usb_endpoint_descriptor_no_audio ep_out;
    } fs_desc;
    struct {
        struct usb_interface_descriptor intf;
        struct usb_endpoint_descriptor_no_audio ep_out;
    } hs_desc;
};

struct string_descs {
    struct usb_functionfs_strings_head header;
    __le16 lang;
    char name[10];
};
#pragma pack(pop)

static int write_descriptors(int ep0) {
    struct full_descs d = {0};
    d.header.magic  = htole32(FUNCTIONFS_DESCRIPTORS_MAGIC_V2);
    d.header.length = htole32(sizeof(d));
    d.header.flags  = htole32(FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC);
    d.fs_count = htole32(2);
    d.hs_count = htole32(2);

    /* Full-speed interface + bulk-out endpoint (max packet 64) */
    d.fs_desc.intf.bLength            = sizeof(d.fs_desc.intf);
    d.fs_desc.intf.bDescriptorType    = USB_DT_INTERFACE;
    d.fs_desc.intf.bInterfaceNumber   = 0;
    d.fs_desc.intf.bNumEndpoints      = 1;
    d.fs_desc.intf.bInterfaceClass    = USB_CLASS_VENDOR_SPEC;
    d.fs_desc.intf.iInterface         = 1;

    d.fs_desc.ep_out.bLength          = USB_DT_ENDPOINT_SIZE;
    d.fs_desc.ep_out.bDescriptorType  = USB_DT_ENDPOINT;
    d.fs_desc.ep_out.bEndpointAddress = USB_DIR_OUT | 1;
    d.fs_desc.ep_out.bmAttributes     = USB_ENDPOINT_XFER_BULK;
    d.fs_desc.ep_out.wMaxPacketSize   = htole16(64);

    /* High-speed mirror with bigger max packet */
    memcpy(&d.hs_desc, &d.fs_desc, sizeof(d.fs_desc));
    d.hs_desc.ep_out.wMaxPacketSize   = htole16(512);

    if (write(ep0, &d, sizeof(d)) != (ssize_t)sizeof(d)) return -1;

    struct string_descs s = {0};
    s.header.magic      = htole32(FUNCTIONFS_STRINGS_MAGIC);
    s.header.length     = htole32(sizeof(s));
    s.header.str_count  = htole32(1);
    s.header.lang_count = htole32(1);
    s.lang              = htole16(0x0409);
    memcpy(s.name, "pidisplay", 10);
    if (write(ep0, &s, sizeof(s)) != (ssize_t)sizeof(s)) return -1;

    return 0;
}

static int bind_udc(void) {
    /* Find UDC name under /sys/class/udc and write it to the gadget's UDC file. */
    DIR *d = opendir("/sys/class/udc");
    if (!d) { info("opendir /sys/class/udc: %s", strerror(errno)); return -1; }
    char udc[64] = {0};
    struct dirent *ent;
    while ((ent = readdir(d))) {
        if (ent->d_name[0] == '.') continue;
        strncpy(udc, ent->d_name, sizeof(udc) - 1);
        break;
    }
    closedir(d);
    if (!udc[0]) { info("no UDC found"); return -1; }

    int fd = open("/sys/kernel/config/usb_gadget/pidisplay/UDC", O_WRONLY);
    if (fd < 0) { info("open UDC file: %s", strerror(errno)); return -1; }
    if (write(fd, udc, strlen(udc)) < 0) { info("write UDC: %s", strerror(errno)); close(fd); return -1; }
    close(fd);
    info("UDC bound: %s", udc);
    return 0;
}

int main(void) {
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    int ep0 = open(FFS_MOUNT "/ep0", O_RDWR);
    if (ep0 < 0) die("open ep0 (%s)", FFS_MOUNT "/ep0");

    if (write_descriptors(ep0) < 0) die("write descriptors");
    info("descriptors written");

    if (bind_udc() < 0) die("bind UDC");

    info("ep0 held; pidisplay should now open ep1 and consume bulk data");
    /* ffs-init's job is to hold ep0 open so the gadget stays active.
     * pidisplay opens ep1 and consumes the actual bulk traffic. */
    while (!g_stop) pause();
    close(ep0);
    return 0;
}
