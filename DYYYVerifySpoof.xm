//
//  DYYYVerifySpoof.xm
//  DYYY++
//
//  认证伪装
//  ───────────────────────────────────────────────────────────────
//  在客户端本地伪造「认证标识 + 认证文案」的展示效果。
//
//  ⚠️ 作用边界：纯渲染层行为。不修改任何服务端数据，不上传任何信息，
//     他人看到的账号信息不受影响（既不会真的获得认证，也不会影响别人）。
//
//  两层实现：
//    1) 视图层（主路径，保证可见）
//       · 个人主页：hook AWEProfileHeaderMyProfileViewController，在其视图树中
//         定位昵称控件，把认证条贴在昵称右侧
//       · 信息流等其它渲染位：hook AWEUserNameLabel（该控件是播放页的作者昵称）
//    2) 模型层（尽力而为）
//       hook AWEUserModel 的认证字段；不同抖音版本字段名可能不同，命中则多一层覆盖，
//       未命中也不影响视图层生效。
//
//  注：不要用「模型层是否被读取」来决定是否走视图层——抖音读这些字段的原因很多，
//      读了不等于渲染出了认证标识，早期版本据此抑制视图层，导致开了完全没效果。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AwemeHeaders.h"
#import "DYYYUtils.h"
#import "DYYYManager.h"

#pragma mark - 配置键

#define DYYY_VERIFY_ENABLED_KEY         @"DYYYEnableVerifySpoof"
#define DYYY_VERIFY_GLOBAL_KEY          @"DYYYVerifySpoofGlobal"
#define DYYY_VERIFY_TEXT_KEY            @"DYYYVerifySpoofText"
#define DYYY_VERIFY_COLOR_KEY           @"DYYYVerifySpoofColor"
#define DYYY_VERIFY_DEBUG_KEY           @"DYYYVerifySpoofDebug"

#define DYYY_VERIFY_TYPE_PERSONAL_KEY   @"DYYYVerifySpoofType_Personal"
#define DYYY_VERIFY_TYPE_ENTERPRISE_KEY @"DYYYVerifySpoofType_Enterprise"
#define DYYY_VERIFY_TYPE_MUSICIAN_KEY   @"DYYYVerifySpoofType_Musician"
#define DYYY_VERIFY_TYPE_CREATOR_KEY    @"DYYYVerifySpoofType_Creator"
#define DYYY_VERIFY_TYPE_MERCHANT_KEY   @"DYYYVerifySpoofType_Merchant"

typedef NS_ENUM(NSInteger, DYYYVerifyKind) {
    DYYYVerifyKindPersonal = 0,   // 黄V 个人认证
    DYYYVerifyKindEnterprise,     // 蓝V 企业认证
    DYYYVerifyKindMusician,       // 音乐人认证
    DYYYVerifyKindCreator,        // 创作者认证
    DYYYVerifyKindMerchant        // 商家认证
};

#pragma mark - 配置读取

static BOOL DYYYVerifySpoofEnabled(void) {
    return DYYYCachedBool(DYYY_VERIFY_ENABLED_KEY);
}

static BOOL DYYYVerifySpoofDebug(void) {
    return DYYYCachedBool(DYYY_VERIFY_DEBUG_KEY);
}

static BOOL DYYYVerifySpoofIsGlobal(void) {
    // 未配置时默认「全局」，与设置页默认值保持一致
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:DYYY_VERIFY_GLOBAL_KEY];
    if (!stored) return YES;
    return DYYYCachedBool(DYYY_VERIFY_GLOBAL_KEY);
}

// 认证类型：同名开关互斥，命中第一个开启的即可（个人认证为默认兜底）
static DYYYVerifyKind DYYYVerifySpoofKind(void) {
    if (DYYYCachedBool(DYYY_VERIFY_TYPE_ENTERPRISE_KEY)) return DYYYVerifyKindEnterprise;
    if (DYYYCachedBool(DYYY_VERIFY_TYPE_MUSICIAN_KEY))   return DYYYVerifyKindMusician;
    if (DYYYCachedBool(DYYY_VERIFY_TYPE_CREATOR_KEY))    return DYYYVerifyKindCreator;
    if (DYYYCachedBool(DYYY_VERIFY_TYPE_MERCHANT_KEY))   return DYYYVerifyKindMerchant;
    return DYYYVerifyKindPersonal;
}

static NSString *DYYYVerifySpoofDefaultText(DYYYVerifyKind kind) {
    switch (kind) {
        case DYYYVerifyKindPersonal:   return @"个人认证";
        case DYYYVerifyKindEnterprise: return @"企业认证";
        case DYYYVerifyKindMusician:   return @"音乐人";
        case DYYYVerifyKindCreator:    return @"优质创作者";
        case DYYYVerifyKindMerchant:   return @"商家认证";
    }
    return @"个人认证";
}

// 认证文案：优先用户自定义，留空则用类型默认文案
static NSString *DYYYVerifySpoofText(void) {
    NSString *custom = DYYYCachedString(DYYY_VERIFY_TEXT_KEY);
    custom = [custom stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (custom.length > 0) return custom;
    return DYYYVerifySpoofDefaultText(DYYYVerifySpoofKind());
}

static UIColor *DYYYVerifySpoofDefaultColor(DYYYVerifyKind kind) {
    switch (kind) {
        case DYYYVerifyKindPersonal:   return [UIColor colorWithRed:1.00 green:0.73 blue:0.15 alpha:1.0]; // 黄V
        case DYYYVerifyKindEnterprise: return [UIColor colorWithRed:0.16 green:0.47 blue:1.00 alpha:1.0]; // 蓝V
        case DYYYVerifyKindMusician:   return [UIColor colorWithRed:0.66 green:0.28 blue:1.00 alpha:1.0];
        case DYYYVerifyKindCreator:    return [UIColor colorWithRed:0.00 green:0.64 blue:0.90 alpha:1.0];
        case DYYYVerifyKindMerchant:   return [UIColor colorWithRed:1.00 green:0.45 blue:0.13 alpha:1.0];
    }
    return [UIColor systemYellowColor];
}

// 认证标识颜色：支持十六进制自定义，留空/非法则用类型默认色
static UIColor *DYYYVerifySpoofBadgeColor(void) {
    NSString *hex = DYYYCachedString(DYYY_VERIFY_COLOR_KEY);
    hex = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (hex.length >= 6) {
        UIColor *custom = [DYYYManager colorWithHexString:hex];
        if (custom) return custom;
    }
    return DYYYVerifySpoofDefaultColor(DYYYVerifySpoofKind());
}

// 认证类型 -> 抖音 verification_type 取值（尽力映射，用于模型层）
static NSInteger DYYYVerifySpoofVerificationTypeValue(void) {
    switch (DYYYVerifySpoofKind()) {
        case DYYYVerifyKindPersonal:   return 1;
        case DYYYVerifyKindEnterprise: return 2;
        case DYYYVerifyKindMusician:   return 3;
        case DYYYVerifyKindCreator:    return 1;
        case DYYYVerifyKindMerchant:   return 2;
    }
    return 1;
}

#pragma mark - 模型层：AWEUserModel 认证字段（尽力而为）

%hook AWEUserModel

- (NSString *)customVerify {
    if (DYYYVerifySpoofEnabled()) {
        return DYYYVerifySpoofText();
    }
    return %orig;
}

- (NSString *)enterpriseVerifyReason {
    if (DYYYVerifySpoofEnabled()) {
        return DYYYVerifySpoofText();
    }
    return %orig;
}

- (NSInteger)verificationType {
    if (DYYYVerifySpoofEnabled()) {
        return DYYYVerifySpoofVerificationTypeValue();
    }
    return %orig;
}

%end

#pragma mark - 视图层

static const void *kDYYYVerifyBadgeKey = &kDYYYVerifyBadgeKey;
static NSInteger const DYYYVerifyBadgeTag = 0x4D5956; // 'MYV'

// 个人主页上定位到的昵称控件（弱引用，视图销毁后自动失效并触发重新扫描）
static __weak UIView *gDYYYVerifyProfileHost = nil;

static NSString *DYYYVerifyLowerClassName(UIView *view) {
    return [NSStringFromClass([view class]) lowercaseString];
}

static void DYYYVerifyBadgeRemove(UIView *host) {
    if (!host) return;
    UIView *badge = objc_getAssociatedObject(host, kDYYYVerifyBadgeKey);
    if (!badge) return;
    [badge removeFromSuperview];
    objc_setAssociatedObject(host, kDYYYVerifyBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 在昵称控件右侧贴上认证条，与抖音自带的认证标识位置一致。
// 每次布局都会重算，保证滚动/旋转/复用后位置正确。
static void DYYYVerifyBadgeApply(UIView *host) {
    if (!host) return;

    UIView *container = host.superview;
    if (!container || host.frame.size.height <= 0.0 || host.hidden) {
        DYYYVerifyBadgeRemove(host);
        return;
    }

    UILabel *badge = objc_getAssociatedObject(host, kDYYYVerifyBadgeKey);
    if (!badge) {
        badge = [[UILabel alloc] initWithFrame:CGRectZero];
        badge.userInteractionEnabled = NO;
        badge.textAlignment = NSTextAlignmentCenter;
        badge.font = [UIFont boldSystemFontOfSize:9.0];
        badge.textColor = [UIColor whiteColor];
        badge.numberOfLines = 1;
        badge.tag = DYYYVerifyBadgeTag;
        badge.layer.cornerRadius = 4.0;
        badge.layer.masksToBounds = YES;
        objc_setAssociatedObject(host, kDYYYVerifyBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container addSubview:badge];
    }

    NSString *text = [NSString stringWithFormat:@"V %@", DYYYVerifySpoofText()];
    if (![badge.text isEqualToString:text]) {
        badge.text = text;
    }

    UIColor *color = DYYYVerifySpoofBadgeColor();
    if (![badge.backgroundColor isEqual:color]) {
        badge.backgroundColor = color;
    }

    [badge sizeToFit];

    CGFloat width = MAX(badge.bounds.size.width + 10.0, 28.0);
    CGFloat height = MAX(badge.bounds.size.height, 14.0);
    CGFloat x = CGRectGetMaxX(host.frame) + 3.0;
    CGFloat y = CGRectGetMidY(host.frame) - height / 2.0;

    // 超出父视图右边界时向内收，保证始终可见
    CGFloat maxX = CGRectGetMaxX(container.bounds) - 2.0;
    if (x + width > maxX) {
        x = MAX(0.0, maxX - width);
    }

    CGRect target = CGRectMake(x, y, width, height);

    // 仅在实际变化时写 frame，避免触发无谓的布局回环
    if (!CGRectEqualToRect(badge.frame, target)) {
        badge.frame = target;
    }

    if (container.subviews.lastObject != badge) {
        [container bringSubviewToFront:badge];
    }
}

#pragma mark - 个人主页：在视图树中定位昵称控件

// 广度优先扫描，返回最像「昵称」的控件。
// 优先按类名匹配（各抖音版本命名不一），找不到再退回几何特征兜底。
static UIView *DYYYVerifyFindNicknameHost(UIView *root, NSMutableArray<NSString *> *debugNames) {
    if (!root) return nil;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    UIView *named = nil;      // 类名命中
    UIView *fallback = nil;   // 几何兜底

    NSUInteger visited = 0;
    NSUInteger cursor = 0;
    while (cursor < queue.count && visited < 4000) {
        UIView *view = [queue objectAtIndex:cursor];
        cursor++;
        visited++;

        NSString *cls = DYYYVerifyLowerClassName(view);

        if (debugNames &&
            ([cls containsString:@"name"] || [cls containsString:@"nick"] ||
             [cls containsString:@"verif"] || [cls containsString:@"cert"] ||
             [cls containsString:@"badge"])) {
            NSString *pretty = NSStringFromClass([view class]);
            if (![debugNames containsObject:pretty]) [debugNames addObject:pretty];
        }

        BOOL laidOut = view.frame.size.width > 0.0 && view.frame.size.height > 0.0;

        if (!named && laidOut &&
            ([cls containsString:@"usernamelabel"] ||
             [cls containsString:@"nickname"] ||
             [cls containsString:@"nicknamelabel"] ||
             [cls containsString:@"namenick"])) {
            named = view;
        }

        // 兜底：主页上半部分、字号较大的非空文本标签
        if (!fallback && laidOut && [view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            if (label.text.length > 0 &&
                label.font.pointSize >= 15.0 &&
                view.frame.size.height <= 44.0 &&
                CGRectGetMidY(view.frame) < CGRectGetHeight(root.bounds) * 0.6) {
                fallback = view;
            }
        }

        [queue addObjectsFromArray:view.subviews];
    }

    return named ?: fallback;
}

static BOOL gDYYYVerifyDebugReported = NO;

static void DYYYVerifyDebugReport(NSMutableArray<NSString *> *names, BOOL found) {
    if (!DYYYVerifySpoofDebug() || gDYYYVerifyDebugReported) return;
    gDYYYVerifyDebugReported = YES;

    NSString *list = names.count > 0 ? [names componentsJoinedByString:@" / "] : @"（无 name/verif 类控件）";
    NSString *msg = [NSString stringWithFormat:@"认证伪装%@：%@", found ? @"已注入" : @"未找到昵称控件", list];
    if (msg.length > 220) msg = [[msg substringToIndex:220] stringByAppendingString:@"…"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [DYYYManager showToast:msg];
    });
}

// 处理个人主页的一次布局：定位昵称控件并贴认证条
static void DYYYVerifyApplyToProfilePage(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return;

    if (!DYYYVerifySpoofEnabled()) {
        if (gDYYYVerifyProfileHost) DYYYVerifyBadgeRemove(gDYYYVerifyProfileHost);
        gDYYYVerifyProfileHost = nil;
        return;
    }

    UIView *host = gDYYYVerifyProfileHost;
    if (!host || !host.superview || host.hidden) {
        NSMutableArray<NSString *> *names = DYYYVerifySpoofDebug() ? [NSMutableArray array] : nil;
        host = DYYYVerifyFindNicknameHost(vc.view, names);
        gDYYYVerifyProfileHost = host;
        if (names) DYYYVerifyDebugReport(names, host != nil);
    }

    if (host) {
        DYYYVerifyBadgeApply(host);
    }
}

// 昵称控件类名在部分版本里不存在，用 %group 做存在性判断后再 %init，
// 避免对不存在的类调用 MSHookMessageEx。
// 该类名沿用项目里已验证可用的写法（见 DYYYSocialStats.xm）。
@interface AWEProfileHeaderMyProfileViewController : UIViewController
- (void)reloadSettings;
@end

%group DYYYVerifyProfilePage

%hook AWEProfileHeaderMyProfileViewController

- (void)viewDidLayoutSubviews {
    %orig;
    DYYYVerifyApplyToProfilePage(self);
}

%end

%end

#pragma mark - 信息流等其它渲染位（仅「全局」模式）

%hook AWEUserNameLabel

- (void)layoutSubviews {
    %orig;

    if (!DYYYVerifySpoofEnabled() || !DYYYVerifySpoofIsGlobal()) {
        DYYYVerifyBadgeRemove(self);
        return;
    }
    DYYYVerifyBadgeApply(self);
}

%end

#pragma mark - 刷新入口

static NSArray<UIWindow *> *DYYYVerifyAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                [windows addObject:window];
            }
        }
    } else {
        [windows addObjectsFromArray:[UIApplication sharedApplication].windows];
    }
    return windows;
}

static void DYYYVerifyWalkViewTree(UIView *view) {
    if (!view) return;

    static Class userNameLabelClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        userNameLabelClass = NSClassFromString(@"AWEUserNameLabel");
    });

    if (userNameLabelClass && [view isKindOfClass:userNameLabelClass]) {
        if (DYYYVerifySpoofIsGlobal()) {
            DYYYVerifyBadgeApply(view);
        } else {
            DYYYVerifyBadgeRemove(view);
        }
    }

    // subviews 返回的是快照数组，遍历中增删子视图安全
    for (UIView *subview in view.subviews) {
        DYYYVerifyWalkViewTree(subview);
    }
}

// 在控制器树中找出当前展示的个人主页控制器（个人主页通常嵌在 Tab/导航容器里）
static UIViewController *DYYYVerifyFindProfileController(UIViewController *vc) {
    if (!vc) return nil;

    Class profileClass = NSClassFromString(@"AWEProfileHeaderMyProfileViewController");
    if (profileClass && [vc isKindOfClass:profileClass]) return vc;

    UIViewController *found = nil;

    found = DYYYVerifyFindProfileController(vc.presentedViewController);
    if (found) return found;

    if ([vc isKindOfClass:[UINavigationController class]]) {
        return DYYYVerifyFindProfileController(((UINavigationController *)vc).topViewController);
    }

    if ([vc isKindOfClass:[UITabBarController class]]) {
        return DYYYVerifyFindProfileController(((UITabBarController *)vc).selectedViewController);
    }

    for (UIViewController *child in vc.childViewControllers) {
        found = DYYYVerifyFindProfileController(child);
        if (found) return found;
    }

    return nil;
}

// 供设置页开关调用：立即刷新当前界面上的认证条。
// 注意：.xm 以 Objective-C++ 编译，跨 TU 导出必须 extern "C"，
// 否则符号会被 C++ name mangling，导致 DYYYSwitchManager.m（C 编译单元）链接失败。
#ifdef __cplusplus
extern "C" {
#endif

void DYYYVerifySpoofRefreshUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 关键控件缓存与一次性调试上报都需要重置
        gDYYYVerifyProfileHost = nil;
        gDYYYVerifyDebugReported = NO;

        for (UIWindow *window in DYYYVerifyAllWindows()) {
            DYYYVerifyWalkViewTree(window);

            // 命中个人主页时立刻按新配置重贴一次
            UIViewController *profileVC = DYYYVerifyFindProfileController(window.rootViewController);
            if (profileVC) {
                DYYYVerifyApplyToProfilePage(profileVC);
            }
        }
    });
}

#ifdef __cplusplus
}
#endif

#pragma mark - 启动自检日志

%ctor {
    // 使用 %group 后自动 %init 被关闭，默认组必须显式初始化
    %init(_ungrouped);

    Class userModelClass = NSClassFromString(@"AWEUserModel");
    if (userModelClass) {
        NSLog(@"[DYYY][VerifySpoof] AWEUserModel customVerify:%d enterpriseVerifyReason:%d verificationType:%d",
              (int)[userModelClass instancesRespondToSelector:NSSelectorFromString(@"customVerify")],
              (int)[userModelClass instancesRespondToSelector:NSSelectorFromString(@"enterpriseVerifyReason")],
              (int)[userModelClass instancesRespondToSelector:NSSelectorFromString(@"verificationType")]);
    } else {
        NSLog(@"[DYYY][VerifySpoof] 未找到 AWEUserModel，全局模式将退回视图层");
    }

    // 个人主页头控制器存在时才挂载对应 hook
    if (NSClassFromString(@"AWEProfileHeaderMyProfileViewController")) {
        %init(DYYYVerifyProfilePage);
        NSLog(@"[DYYY][VerifySpoof] 已挂载个人主页 hook");
    } else {
        NSLog(@"[DYYY][VerifySpoof] 未找到 AWEProfileHeaderMyProfileViewController，主页仅靠昵称控件注入");
    }
}
