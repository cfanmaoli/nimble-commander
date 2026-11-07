// Baseline for the enumeration numbers: reads a directory straight from the kernel, without any
// of the app's machinery, so that "how much of the time is the kernel's" can be answered.
//
// usage: enum_baseline <dir> [full|notimes|nameonly] [buffer-size]
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    if( argc < 2 ) {
        fprintf(stderr, "usage: %s <dir> [full|notimes|nameonly] [buffer-size]\n", argv[0]);
        return 1;
    }
    const char *path = argv[1];
    const char *set = argc > 2 ? argv[2] : "full";
    size_t bufsz = argc > 3 ? (size_t)atol(argv[3]) : 1048576;

    // readdir first: this is the cheapest enumeration the kernel offers
    {
        int fd = open(path, O_RDONLY | O_DIRECTORY);
        if( fd < 0 ) {
            perror("open");
            return 1;
        }
        DIR *dir = fdopendir(fd);
        size_t n = 0;
        const double t0 = now();
        struct dirent *e;
        while( (e = readdir(dir)) )
            ++n;
        const double t1 = now();
        printf("readdir  entries=%zu time=%.3fs rate=%.0f/s\n", n, t1 - t0, n / (t1 - t0));
        closedir(dir);
    }

    int fd = open(path, O_RDONLY | O_DIRECTORY);
    if( fd < 0 ) {
        perror("open");
        return 1;
    }
    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    if( !strcmp(set, "full") ) {
        al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_DEVID |
                        ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME |
                        ATTR_CMN_ACCTIME | ATTR_CMN_ADDEDTIME | ATTR_CMN_OWNERID | ATTR_CMN_GRPID |
                        ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
        al.fileattr = ATTR_FILE_DATALENGTH;
        al.forkattr = ATTR_CMNEXT_EXT_FLAGS;
    }
    else if( !strcmp(set, "notimes") ) {
        al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE |
                        ATTR_CMN_FILEID;
        al.fileattr = ATTR_FILE_DATALENGTH;
    }
    else {
        al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR;
    }

    char *buf = malloc(bufsz);
    if( !buf )
        return 1;
    size_t total = 0, calls = 0;
    const double t0 = now();
    while( 1 ) {
        const int n = getattrlistbulk(fd, &al, buf, bufsz, FSOPT_ATTR_CMN_EXTENDED);
        if( n <= 0 )
            break;
        total += (size_t)n;
        ++calls;
    }
    const double t1 = now();
    printf("bulk/%-8s entries=%zu calls=%zu buf=%zu time=%.3fs rate=%.0f/s\n",
           set,
           total,
           calls,
           bufsz,
           t1 - t0,
           total / (t1 - t0));
    close(fd);
    free(buf);
    return 0;
}
