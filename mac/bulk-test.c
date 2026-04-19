/*
 * Quick libusb test: find the Pi Display Gadget, claim its vendor-specific
 * interface (class 0xFF), and send a burst of bulk packets. Pi side
 * (ffs-init) should log the total MB/s received.
 *
 * Build:
 *   clang -O2 -Wall bulk-test.c -I$(brew --prefix libusb)/include/libusb-1.0 \
 *         -L$(brew --prefix libusb)/lib -lusb-1.0 -o bulk-test
 */
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VID 0x1d6b
#define PID 0x0104
#define IFACE 2
#define EP_OUT 0x02   /* bulk OUT endpoint — 0x02 because CDC-ECM has 0x01 */

int main(int argc, char **argv) {
    int n_mb = (argc >= 2) ? atoi(argv[1]) : 64;
    libusb_context *ctx = NULL;
    if (libusb_init(&ctx) < 0) { fprintf(stderr, "libusb_init failed\n"); return 1; }

    libusb_device_handle *dev = libusb_open_device_with_vid_pid(ctx, VID, PID);
    if (!dev) { fprintf(stderr, "device %04x:%04x not found\n", VID, PID); return 2; }

    /* macOS auto-attaches kernel drivers; detach for our interface. */
    if (libusb_kernel_driver_active(dev, IFACE) > 0) {
        libusb_detach_kernel_driver(dev, IFACE);
    }
    if (libusb_claim_interface(dev, IFACE) < 0) {
        fprintf(stderr, "claim interface %d failed\n", IFACE);
        return 3;
    }

    size_t chunk = 32 * 1024;  /* 32 KiB */
    unsigned char *buf = malloc(chunk);
    memset(buf, 0xAB, chunk);

    size_t total_bytes = (size_t)n_mb * 1024 * 1024;
    size_t sent = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    while (sent < total_bytes) {
        int actual = 0;
        size_t want = total_bytes - sent < chunk ? (total_bytes - sent) : chunk;
        int r = libusb_bulk_transfer(dev, EP_OUT, buf, (int)want, &actual, 2000);
        if (r < 0) {
            fprintf(stderr, "bulk_transfer: %s (sent=%zu)\n", libusb_strerror(r), sent);
            break;
        }
        sent += actual;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    fprintf(stderr, "sent %.1f MB in %.2f s -> %.1f MB/s\n",
            sent / 1e6, dt, sent / dt / 1e6);

    libusb_release_interface(dev, IFACE);
    libusb_close(dev);
    libusb_exit(ctx);
    return 0;
}
