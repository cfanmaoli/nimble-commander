// Generates a directory with a given number of files, for the performance benchmarks.
// usage: ./gen <dir> <count> <threads>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static const char *dir;
static long total;
static int nthreads;

static void *worker(void *arg)
{
    const long t = (long)arg;
    char name[512];
    for( long i = t; i < total; i += nthreads ) {
        snprintf(name, sizeof name, "%s/f_%07ld.txt", dir, i);
        const int fd = open(name, O_CREAT | O_WRONLY, 0644);
        if( fd < 0 ) {
            perror("open");
            exit(1);
        }
        if( i % 10 == 0 )
            (void)!write(fd, "x", 1);
        close(fd);
    }
    return NULL;
}

int main(int argc, char **argv)
{
    if( argc != 4 ) {
        fprintf(stderr, "usage: %s <dir> <count> <threads>\n", argv[0]);
        return 1;
    }
    dir = argv[1];
    total = atol(argv[2]);
    nthreads = atoi(argv[3]);
    pthread_t th[64];
    for( long i = 0; i < nthreads; ++i )
        pthread_create(&th[i], NULL, worker, (void *)i);
    for( int i = 0; i < nthreads; ++i )
        pthread_join(th[i], NULL);
    return 0;
}
