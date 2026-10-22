/* Injected macOS side of qa/n/exit-hang.sh (wz-n-0011).
 *
 * A DYLD_INSERT_LIBRARIES dylib that interposes pthread_create. For a thread created with a caller-supplied stack (a
 * Wine kernel thread from spawn_thread()) it wraps the start routine so the thread arms a fault that fires in one of
 * its pthread TSD destructors when it exits, after pthread_exit_wrapper() has closed its server fds.
 * $WZ_EXIT_HANG_MODE:
 *
 *   pool     (default) autorelease, with no pool in place, an object whose -release writes to address 8, then a plain
 *            NSObject, so the faulting object sits in a real pool page: objc's hot-page TSD destructor (static key 43)
 *            drains it in AutoreleasePoolPage::releaseUntil at pthread_exit, after Wine's own TSD keys (thread_data,
 *            TEB) were cleared.
 *   elision  autorelease only the faulting object: it stays in objc's deferred-autorelease slot (static key 44) and
 *            that slot's destructor releases it, again with Wine's keys already cleared.
 *   tlv      register a faulting C++ thread_local destructor (_tlv_atexit, what clang emits): dyld's terminator key
 *            was made before Wine's keys, so it runs while get_thread_data() still returns the thread's data.
 *   align    like pool, but -release takes an alignment fault (ldxr from a misaligned address).
 *   abort    like pool, but -release calls abort().
 *   trap     like pool, but -release executes __builtin_trap() (as os_crash, libdispatch and libmalloc reports do).
 *   guard    no Wine thread is touched: a native thread (no Wine thread data, like a GCD or Metal thread) reads the
 *            PAGE_GUARD page the test program publishes in C:\wz-exit-hang-guard.txt, then creates
 *            C:\wz-exit-hang-guard.done.
 *
 * Writes "wz-pool-fault: wrapped" for each wrapped thread and "wz-pool-fault: faulting" for each fault to stderr,
 * which qa/n/exit-hang.sh counts. Acts only when WZ_EXIT_HANG_TEST is set and argv names the test program, so
 * wineserver and the other Wine processes the injection reaches stay untouched. Compiled MRC (-fno-objc-arc) to call
 * -autorelease and -release directly.
 */
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <crt_externs.h>
#include <stdio.h>

enum wz_mode { WZ_POOL, WZ_ELISION, WZ_TLV, WZ_ALIGN, WZ_ABORT, WZ_TRAP, WZ_GUARD };
static const char *const wz_mode_names[] = { "pool", "elision", "tlv", "align", "abort", "trap", "guard" };
static enum wz_mode wz_mode = WZ_POOL;

/* dyld registers a C++ thread_local destructor with this; it runs at thread exit from dyld's TLV terminator key */
extern void _tlv_atexit( void (*termfunc)( void *objAddr ), void *objAddr );

static void wz_say( const char *msg )
{
    write( 2, msg, strlen( msg ) );
}

static void wz_fire( void )
{
    wz_say( "wz-pool-fault: faulting\n" );
    switch (wz_mode)
    {
    case WZ_ABORT:
        abort();
    case WZ_TRAP:
        __builtin_trap();
    case WZ_ALIGN:
    {
        static unsigned long buf[8];
        unsigned long value, *misaligned = (unsigned long *)((((unsigned long)buf + 15) & ~15UL) + 13);
        __asm__ volatile( "ldxr %0, [%1]" : "=r"(value) : "r"(misaligned) : "memory" );
        (void)value;
        break;   /* not reached: an exclusive load from a misaligned address is an alignment fault */
    }
    default:
        break;
    }
    *(volatile long *)8 = 1;   /* a write to a near-NULL address */
}

@interface WZExitFault : NSObject
@end

@implementation WZExitFault
- (oneway void)release
{
    /* Never calls [super release]: the object is not freed. */
    wz_fire();
}
@end

static void wz_tlv_terminator( void *unused )
{
    (void)unused;
    wz_fire();
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

/* Active only with the env var set and only in the process whose argv names the test program. */
static int wz_active( void )
{
    static int cached = -1;
    if (cached >= 0) return cached;
    cached = 0;
    if (getenv( "WZ_EXIT_HANG_TEST" ))
    {
        char ***argvp = _NSGetArgv();
        int *argcp = _NSGetArgc();
        const char *mode = getenv( "WZ_EXIT_HANG_MODE" );
        unsigned int m;

        if (mode)
            for (m = 0; m < sizeof(wz_mode_names) / sizeof(wz_mode_names[0]); m++)
                if (!strcmp( mode, wz_mode_names[m] )) wz_mode = (enum wz_mode)m;
        if (argvp && argcp && *argvp)
        {
            int i;
            for (i = 0; i < *argcp; i++)
                if ((*argvp)[i] && strstr( (*argvp)[i], "wz-exit-thread" )) { cached = 1; break; }
        }
    }
    return cached;
}

struct wz_start { void *(*fn)( void * ); void *arg; };

static void *wz_thread_start( void *p )
{
    struct wz_start s = *(struct wz_start *)p;
    free( p );
    switch (wz_mode)
    {
    case WZ_TLV:
        _tlv_atexit( wz_tlv_terminator, NULL );
        break;
    case WZ_ELISION:
        [[[WZExitFault alloc] init] autorelease];
        break;
    default:
        /* the second autorelease moves the first object out of the deferred slot into a pool page */
        [[[WZExitFault alloc] init] autorelease];
        [[[NSObject alloc] init] autorelease];
        break;
    }
    return s.fn( s.arg );
}

static int wz_pthread_create( pthread_t *thread, const pthread_attr_t *attr,
                              void *(*start)( void * ), void *arg )
{
    /* Call pthread_create() directly by name: dyld interposes the symbol in every other image and in dlsym()
     * results, but not the interposer's own direct calls, so this reaches the real libpthread pthread_create. */
    if (wz_active() && wz_mode != WZ_GUARD && attr)
    {
        void *stackaddr = NULL;
        size_t stacksize = 0;
        if (pthread_attr_getstack( attr, &stackaddr, &stacksize ) == 0 && stackaddr)
        {
            struct wz_start *s = malloc( sizeof(*s) );
            if (s)
            {
                char line[96];   /* one write per line: qa/n/exit-hang.sh counts these lines */
                strlcpy( line, "wz-pool-fault: wrapped a Wine thread (mode ", sizeof(line) );
                strlcat( line, wz_mode_names[wz_mode], sizeof(line) );
                strlcat( line, ")\n", sizeof(line) );
                wz_say( line );
                s->fn = start;
                s->arg = arg;
                return pthread_create( thread, attr, wz_thread_start, s );
            }
        }
    }
    return pthread_create( thread, attr, start, arg );
}

DYLD_INTERPOSE( wz_pthread_create, pthread_create )

/* guard mode: a native thread waits for the address the test program publishes, then reads that PAGE_GUARD page */
static void *wz_guard_toucher( void *unused )
{
    const char *prefix = getenv( "WINEPREFIX" );
    char path[2048], done[2048];
    int i;

    (void)unused;
    if (!prefix) return NULL;
    snprintf( path, sizeof(path), "%s/drive_c/wz-exit-hang-guard.txt", prefix );
    snprintf( done, sizeof(done), "%s/drive_c/wz-exit-hang-guard.done", prefix );
    for (i = 0; i < 600; i++)
    {
        unsigned long long addr = 0;
        FILE *f = fopen( path, "r" );

        if (f)
        {
            int ok = fscanf( f, "%llx", &addr ) == 1 && addr;
            fclose( f );
            if (ok)
            {
                wz_say( "wz-pool-fault: native thread reads a guard page\n" );
                (void)*(volatile char *)(unsigned long)addr;
                wz_say( "wz-pool-fault: native thread got past the guard page\n" );
                if ((f = fopen( done, "w" ))) fclose( f );
                return NULL;
            }
        }
        usleep( 50000 );
    }
    return NULL;
}

__attribute__((constructor)) static void wz_guard_init( void )
{
    pthread_t thread;

    if (!wz_active() || wz_mode != WZ_GUARD) return;
    wz_say( "wz-pool-fault: guard mode, native thread started\n" );
    if (!pthread_create( &thread, NULL, wz_guard_toucher, NULL )) pthread_detach( thread );
}
