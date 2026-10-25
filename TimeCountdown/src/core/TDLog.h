//
//  TDLog —— 主 App 与 HUD 进程共用的落盘日志 + 崩溃循环保护
//
//  为什么要写文件而不是只用 os_log：
//  HUD 是以 root 身份跑的独立进程，出事的时候设备往往正在 respring，
//  根本来不及用 Console 去看。所以每一条关键步骤都落到一个
//  两边都能读的绝对路径文件里，重启之后打开 App 就能看到。
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

/// 写一行日志（同步落盘，带时间戳和 pid）。同步是有意为之：
/// 万一某一步把系统卡住了，日志必须已经写下去。
void TDLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 读回全部日志（过长时只取尾部）。永远不返回 nil。
NSString *TDLogReadAll(void);

/// 清空日志
void TDLogClear(void);

/// 崩溃循环保护：记一次「HUD 启动」，返回最近 window 秒内累计启动了几次。
/// 连续多次说明上一轮把系统搞挂了（respring 后又被拉起来），
/// 这时候必须主动停下，否则设备会一直在黑屏转圈里出不来。
int TDBootGuardTick(NSTimeInterval window);

/// 只看当前计数，不累加。主 App 用它来提醒用户「上次出事过」。
int TDBootGuardPeek(void);

/// 用户手动点「启动悬浮窗」时清掉计数 —— 那是明确的意图，不该被历史拖累。
void TDBootGuardReset(void);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
