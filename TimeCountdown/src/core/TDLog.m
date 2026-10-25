#import "TDLog.h"

#import <os/log.h>
#import <stdarg.h>
#import <sys/stat.h>
#import <unistd.h>

#ifndef TD_LOG_PATH
#define TD_LOG_PATH @"/var/mobile/Library/Preferences/com.tp2.timecountdown.log"
#endif

// 超过这个大小就清掉重来，免得把用户的可用空间吃掉
#define TD_LOG_MAX_BYTES (256ULL * 1024ULL)

static NSLock *TDLogLock(void)
{
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

static NSString *TDStamp(void)
{
    static NSDateFormatter *fmt = nil;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    }
    return [fmt stringFromDate:[NSDate date]];
}

void TDLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    os_log(OS_LOG_DEFAULT, "[TD] %{public}@", msg);

    NSLock *lock = TDLogLock();
    [lock lock];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:TD_LOG_PATH error:nil];
    if ([attr[NSFileSize] unsignedLongLongValue] > TD_LOG_MAX_BYTES)
        [fm removeItemAtPath:TD_LOG_PATH error:nil];
    if (![fm fileExistsAtPath:TD_LOG_PATH]) {
        [fm createFileAtPath:TD_LOG_PATH
                    contents:nil
                  attributes:@{ NSFilePosixPermissions: @0666 }];
    }

    NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n", TDStamp(), getpid(), msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:TD_LOG_PATH];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) {
            (void)e;
        }
        [fh closeFile];
    }
    // HUD 以 root 追加过之后，要让 mobile 也能继续写
    chmod(TD_LOG_PATH.UTF8String, 0666);

    [lock unlock];
}

NSString *TDLogReadAll(void)
{
    NSLock *lock = TDLogLock();
    [lock lock];
    NSString *s = [NSString stringWithContentsOfFile:TD_LOG_PATH
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
    [lock unlock];

    if (s.length == 0)
        return @"（暂无日志。先去点一次「启动悬浮窗」或「安全诊断」。）";

    if (s.length > 60000)
        s = [@"……（只显示最后 60000 字符）\n" stringByAppendingString:
             [s substringFromIndex:s.length - 60000]];
    return s;
}

void TDLogClear(void)
{
    NSLock *lock = TDLogLock();
    [lock lock];
    [[NSFileManager defaultManager] removeItemAtPath:TD_LOG_PATH error:nil];
    [lock unlock];
}

#pragma mark - 崩溃循环保护

static NSString *TDBootGuardPath(void)
{
    return [TD_LOG_PATH stringByAppendingString:@".guard"];
}

int TDBootGuardTick(NSTimeInterval window)
{
    NSLock *lock = TDLogLock();
    [lock lock];

    NSString *path = TDBootGuardPath();
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];

    double now = [NSDate date].timeIntervalSince1970;
    double last = [d[@"last"] doubleValue];
    int streak = [d[@"streak"] intValue];

    // 距离上次启动很近 -> 上一轮没跑住，累加；否则从头算
    if (last > 0 && (now - last) < window)
        streak += 1;
    else
        streak = 1;

    d[@"last"] = @(now);
    d[@"streak"] = @(streak);

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions: @0777 }
                        error:nil];
    [d writeToFile:path atomically:YES];
    chmod(path.UTF8String, 0666);

    [lock unlock];
    return streak;
}

void TDBootGuardReset(void)
{
    NSLock *lock = TDLogLock();
    [lock lock];
    [[NSFileManager defaultManager] removeItemAtPath:TDBootGuardPath() error:nil];
    [lock unlock];
}

int TDBootGuardPeek(void)
{
    NSLock *lock = TDLogLock();
    [lock lock];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:TDBootGuardPath()];
    int streak = [d[@"streak"] intValue];
    [lock unlock];
    return streak;
}
