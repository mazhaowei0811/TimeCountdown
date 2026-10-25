#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

OBJC_EXTERN BOOL IsHUDEnabled(void);
OBJC_EXTERN void SetHUDEnabled(BOOL isEnabled);
OBJC_EXTERN void waitForNotification(void (^onFinish)(void), BOOL isEnabled);

/// 以 root 身份跑一个自己的副本并等它结束，返回退出码。
/// 主 App 借它做自检 —— 主进程本身没有截屏所需的身份。
OBJC_EXTERN int TDRunSelfSync(NSString *arg);

NS_ASSUME_NONNULL_END
