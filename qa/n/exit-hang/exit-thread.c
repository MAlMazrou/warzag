/* Windows side of qa/n/exit-hang.sh (wz-n-0011).
 *
 * Creates a thread and waits for it (20 s), three times. Injected with exit-hang/pool-fault.m, each worker faults in
 * one of its pthread TSD destructors while it exits. After each round the main thread checks that an access violation
 * is still caught (IsBadReadPtr reads address 16 under SEH): fault signals left blocked or at SIG_DFL would hang or
 * kill the process there. Prints "ALL OK" at the end; an engine without the fix stops at "FAIL round 2", because
 * exit_thread() joins the first worker, which never finishes.
 *
 * With WZ_EXIT_HANG_MODE=guard it publishes a PAGE_GUARD page for the injected native thread, waits until that thread
 * got past it, and checks that a write-watch fault and an access violation are still handled.
 *
 * A bare console program (llvm-mingw, aarch64), so the only Wine threads it spawns are its own.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static DWORD WINAPI worker( LPVOID arg )
{
    volatile unsigned sum = 0;
    unsigned i;
    (void)arg;
    for (i = 0; i < 100000; i++) sum += i;   /* a little work, then return so the thread exits */
    return 0;
}

static int guard_mode( void )
{
    static const char ready[] = "C:\\wz-exit-hang-guard.txt", tmp[] = "C:\\wz-exit-hang-guard.tmp";
    static const char done[] = "C:\\wz-exit-hang-guard.done";
    char *guard = VirtualAlloc( NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD );
    volatile char *watched;
    FILE *f;
    int i;

    if (!guard)
    {
        printf( "FAIL guard: VirtualAlloc(PAGE_GUARD) failed (%lu)\n", (unsigned long)GetLastError() );
        return 2;
    }
    DeleteFileA( done );
    if (!(f = fopen( tmp, "w" ))) { printf( "FAIL guard: cannot write %s\n", tmp ); return 2; }
    fprintf( f, "%llx\n", (unsigned long long)(ULONG_PTR)guard );
    fclose( f );
    MoveFileExA( tmp, ready, MOVEFILE_REPLACE_EXISTING );
    for (i = 0; i < 400 && GetFileAttributesA( done ) == INVALID_FILE_ATTRIBUTES; i++) Sleep( 50 );
    DeleteFileA( ready );
    if (i == 400)
    {
        printf( "FAIL guard: the native thread did not get past the guard page within 20 s\n" );
        return 1;
    }
    printf( "ok guard: a native thread got past a guard page\n" );
    fflush( stdout );

    if (!(watched = VirtualAlloc( NULL, 0x10000, MEM_RESERVE | MEM_COMMIT | MEM_WRITE_WATCH, PAGE_READWRITE )))
    {
        printf( "FAIL guard: VirtualAlloc(MEM_WRITE_WATCH) failed (%lu)\n", (unsigned long)GetLastError() );
        return 2;
    }
    watched[0] = 1;   /* the first write to a watched page faults; Wine records it and lets it through */
    printf( "probe ok: a write-watch fault is still handled\n" );
    fflush( stdout );
    if (!IsBadReadPtr( (void *)16, 8 ))
    {
        printf( "FAIL guard: an access violation was not caught (IsBadReadPtr)\n" );
        return 1;
    }
    printf( "probe ok: an access violation is still caught\n" );
    printf( "ALL OK\n" );
    fflush( stdout );
    return 0;
}

int main( void )
{
    char mode[16];
    int round;

    if (GetEnvironmentVariableA( "WZ_EXIT_HANG_MODE", mode, sizeof(mode) ) && !strcmp( mode, "guard" ))
        return guard_mode();

    for (round = 1; round <= 3; round++)
    {
        HANDLE h = CreateThread( NULL, 0, worker, NULL, 0, NULL );
        DWORD r;

        if (!h)
        {
            printf( "FAIL round %d: CreateThread failed (%lu)\n", round, (unsigned long)GetLastError() );
            fflush( stdout );
            return 2;
        }
        r = WaitForSingleObject( h, 20000 );
        if (r != WAIT_OBJECT_0)
        {
            printf( "FAIL round %d: thread did not finish within 20 s (WaitForSingleObject=%lu)\n",
                    round, (unsigned long)r );
            fflush( stdout );
            return 1;
        }
        CloseHandle( h );
        printf( "ok round %d\n", round );
        fflush( stdout );
        if (!IsBadReadPtr( (void *)16, 8 ))
        {
            printf( "FAIL round %d: an access violation was not caught (IsBadReadPtr)\n", round );
            fflush( stdout );
            return 1;
        }
        printf( "probe %d ok: an access violation is still caught\n", round );
        fflush( stdout );
    }

    printf( "ALL OK\n" );
    fflush( stdout );
    return 0;
}
