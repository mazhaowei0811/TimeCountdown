#import "HUDHelper.h"
#import <spawn.h>
#import <notify.h>
#import <signal.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <unistd.h>
#import <errno.h>
#import <sys/wait.h>
#import <sys/stat.h>

extern char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attrp, uid_t persona_id, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attrp, uid_t persona_uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attrp, uid_t persona_gid);

/// 把自己拷到容器外的稳定路径再 spawn —— App 容器内的进程可能被设备上的
/// 注入框架（MATweakEx 等）拦截挂死，容器外同字节二进制可正常运行。
static char *TDResolveSpawnPath(void)
{
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *selfBuf = (char *)calloc(1, size);
    _NSGetExecutablePath(selfBuf, &size);
    NSString *selfPath = [NSString stringWithUTF8String:selfBuf];
    free(selfBuf);

    NSString *dir = @"/var/tmp/td-hud";
    NSString *dest = [dir stringByAppendingPathComponent:@"TimeCountdown"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *srcAttr = [fm attributesOfItemAtPath:selfPath error:nil];
    NSDictionary *dstAttr = [fm attributesOfItemAtPath:dest error:nil];
    BOOL needCopy = YES;
    if (srcAttr && dstAttr &&
        [srcAttr[NSFileSize] unsignedLongLongValue] == [dstAttr[NSFileSize] unsignedLongLongValue])
        needCopy = NO;   // 同大小即视为已同步（二进制由 CI 出包，内容随版本变化）

    if (needCopy) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:dest error:nil];
        NSString *plistDest = [dir stringByAppendingPathComponent:@"Info.plist"];
        [fm removeItemAtPath:plistDest error:nil];
        NSString *plistSrc = [[selfPath stringByDeletingLastPathComponent]
                              stringByAppendingPathComponent:@"Info.plist"];
        if ([fm copyItemAtPath:selfPath toPath:dest error:nil])
            chmod(dest.UTF8String, 0755);
        if ([fm fileExistsAtPath:plistSrc])
            [fm copyItemAtPath:plistSrc toPath:plistDest error:nil];
    }
    if ([fm isExecutableFileAtPath:dest])
        return strdup(dest.UTF8String);
    return strdup(selfPath.UTF8String);   // 拷贝失败就退回原路径
}

/// 用指定可执行文件起一个进程，带指定参数。
/// persona 设为 0:0 + OVERRIDE，配合 com.apple.private.persona-mgmt
/// 权限，子进程就是以 root 跑的 —— 截屏和挂悬浮窗都需要这个身份。
static pid_t TDSpawnSelf(const char *arg, BOOL newProcessGroup, int *outStatus)
{
    static char *executablePath = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        executablePath = TDResolveSpawnPath();
    });

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    if (newProcessGroup) {
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    }

    pid_t pid = 0;
    const char *args[] = { executablePath, arg, NULL };
    int rc = posix_spawn(&pid, executablePath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        os_log_error(OS_LOG_DEFAULT, "[TD] posix_spawn(%{public}s) 失败: %d", arg, rc);
        return -1;
    }
    if (outStatus) {
        int status = 0;
        while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {}
        *outStatus = status;
    }
    return pid;
}

BOOL IsHUDEnabled(void)
{
    int status = 0;
    if (TDSpawnSelf("-check", NO, &status) < 0)
        return NO;
    return WEXITSTATUS(status) != 0;
}

int TDRunSelfSync(NSString *arg)
{
    int status = 0;
    if (TDSpawnSelf(arg.UTF8String, NO, &status) < 0)
        return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

void SetHUDEnabled(BOOL isEnabled)
{
    if (isEnabled) {
        TDSpawnSelf("-hud", YES, NULL);
    } else {
        // 给正在运行的 HUD 一点时间把窗口淡出
        [NSThread sleepForTimeInterval:0.25];
        TDSpawnSelf("-exit", NO, NULL);
    }
}

void waitForNotification(void (^onFinish)(void), BOOL isEnabled)
{
    if (!isEnabled) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (onFinish) onFinish();
        });
        return;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    int token = 0;
    notify_register_dispatch(NOTIFY_LAUNCHED_HUD, &token, dispatch_get_main_queue(), ^(int t) {
        notify_cancel(t);
        dispatch_semaphore_signal(semaphore);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        long timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                                                        (int64_t)(5.0 * NSEC_PER_SEC)));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (timedOut)
                os_log_error(OS_LOG_DEFAULT, "[TD] 等待 HUD 启动超时");
            if (onFinish) onFinish();
        });
    });
}
