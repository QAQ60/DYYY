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
//  生效范围（设置页可切）：
//    · 全局（默认）：个人主页 / 评论区 / 视频作者 / 粉丝列表等所有渲染位
//    · 仅个人主页  ：只在「我」的个人主页昵称下方注入认证条
//
//  实现分两层：
//    1) 模型层：hook AWEUserModel 的认证字段 getter（全局模式）
//    2) 视图层：在个人主页昵称控件旁注入认证条（仅主页模式；全局模式下若
//       模型层字段未命中，自动兜底补位，避免出现「开了却什么都看不到」）
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

#pragma mark - 模型层：AWEUserModel 认证字段

// 记录模型层是否真的被抖音读取过：
// 若字段命中，抖音会调用我们 hook 的 getter，标记置位；
// 若始终未置位说明当前版本字段名不匹配，视图层会自动兜底。
static BOOL gDYYYVerifyModelHookFired = NO;

%hook AWEUserModel

- (NSString *)customVerify {
    if (DYYYVerifySpoofEnabled() && DYYYVerifySpoofIsGlobal()) {
        gDYYYVerifyModelHookFired = YES;
        return DYYYVerifySpoofText();
    }
    return %orig;
}

- (NSString *)enterpriseVerifyReason {
    if (DYYYVerifySpoofEnabled() && DYYYVerifySpoofIsGlobal()) {
        gDYYYVerifyModelHookFired = YES;
        return DYYYVerifySpoofText();
    }
    return %orig;
}

- (NSInteger)verificationType {
    if (DYYYVerifySpoofEnabled() && DYYYVerifySpoofIsGlobal()) {
        gDYYYVerifyModelHookFired = YES;
        return DYYYVerifySpoofVerificationTypeValue();
    }
    return %orig;
}

%end

#pragma mark - 视图层

static const void *kDYYYVerifyBadgeKey = &kDYYYVerifyBadgeKey;
static NSInteger const DYYYVerifyBadgeTag = 0x4D5956; // 'MYV'

// 判断该昵称控件是否位于「个人主页」上下文（评论区/信息流作者名不在其列）
static BOOL DYYYVerifyIsInProfileHeader(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            NSString *className = NSStringFromClass([responder class]);
            if ([className containsString:@"ProfileHeader"] ||
                [className containsString:@"MyProfile"] ||
                [className containsString:@"UserHome"] ||
                [className containsString:@"ProfileViewController"]) {
                return YES;
            }
            return NO;
        }
        responder = [responder nextResponder];
    }
    return NO;
}

static BOOL DYYYVerifyShouldUseViewLayer(UIView *host) {
    if (!DYYYVerifySpoofEnabled()) return NO;
    // 全局模式且模型层已生效时不再注入，避免与抖音自带的认证标识重复
    if (DYYYVerifySpoofIsGlobal() && gDYYYVerifyModelHookFired) return NO;
    return DYYYVerifyIsInProfileHeader(host);
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

    if (!DYYYVerifyShouldUseViewLayer(host)) {
        DYYYVerifyBadgeRemove(host);
        return;
    }

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

    // 超出父视图右边界时向内收，保证始终可见（不做裁切，也就不会把昵称盖住太多）
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

static void DYYYVerifyWalkViewTree(UIView *view) {
    if (!view) return;

    static Class userNameLabelClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        userNameLabelClass = NSClassFromString(@"AWEUserNameLabel");
    });

    if (userNameLabelClass && [view isKindOfClass:userNameLabelClass]) {
        DYYYVerifyBadgeApply(view);
    }

    // subviews 返回的是快照数组，遍历中增删子视图安全
    for (UIView *subview in view.subviews) {
        DYYYVerifyWalkViewTree(subview);
    }
}

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

// 供设置页开关调用：立即刷新当前界面上的认证条
void DYYYVerifySpoofRefreshUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!DYYYVerifySpoofEnabled()) {
            // 关闭时清掉已注入的认证条
            gDYYYVerifyModelHookFired = NO;
        }
        for (UIWindow *window in DYYYVerifyAllWindows()) {
            DYYYVerifyWalkViewTree(window);
        }
    });
}

%hook AWEUserNameLabel

- (void)layoutSubviews {
    %orig;
    DYYYVerifyBadgeApply(self);
}

%end

#pragma mark - 启动自检日志

%ctor {
    Class userModelClass = NSClassFromString(@"AWEUserModel");
    if (userModelClass) {
        NSLog(@"[DYYY][VerifySpoof] AWEUserModel customVerify:%d enterpriseVerifyReason:%d verificationType:%d",
              (int)[userModelClass instancesRespondToSelector:NSSelectorFromString(@"customVerify")],
              (int)[userModelClass instancesRespondToSelector:NSSelectorFromString(@"enterpriseVerifyReason")],
              (int)[userModelClass instancesRespondToSelector:NSSelectorFromString(@"verificationType")]);
    } else {
        NSLog(@"[DYYY][VerifySpoof] 未找到 AWEUserModel，全局模式将退回视图层");
    }
}
