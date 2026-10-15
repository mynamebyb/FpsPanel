//
//  FpsPanel.m — 专业游戏监控悬浮窗（standalone 注入 dylib）
//
//  免越狱注入（Sideloadly / 证书直签 / LiveContainer+ElleKit 均可）。
//  功能：悬浮球可拖动，点击展开毛玻璃面板；
//        实时显示 FPS / 帧延迟 / CPU / 内存 / 时间；
//        开关收纳在抽屉里，点右上角 ⚙️ 展开。
//  纯 ObjC Runtime + 公开 API，不依赖 Substrate/ElleKit。
//
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

// ============================================================
#pragma mark - 悬浮窗窗口（关键：空白区域不拦截触摸，穿透给游戏）
// ============================================================

@interface OverlayWindow : UIWindow
@end

@implementation OverlayWindow

// 命中 window 自己 或 全屏透明的 rootViewController.view（空白区域）→ 穿透给游戏；
// 命中悬浮球/面板等子视图 → 正常响应
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view)
        return nil;
    return hit;
}

@end

// ============================================================
#pragma mark - 监控数据采集（FPS / CPU / 内存）
// ============================================================

@interface Metrics : NSObject
@property (nonatomic, assign) float fps;
@property (nonatomic, assign) float cpuUsage;
+ (instancetype)shared;
- (void)start;
- (float)memMB;
@end

@implementation Metrics {
    CADisplayLink *_link;
    NSTimeInterval _lastTs;
    NSInteger _frames;
    host_cpu_load_info_data_t _prevCpu;
    BOOL _hasPrevCpu;
}

+ (instancetype)shared {
    static Metrics *inst;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ inst = [Metrics new]; });
    return inst;
}

- (void)start {
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _lastTs = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                   selector:@selector(sampleCpu)
                                   userInfo:nil repeats:YES];
}

// ---- FPS：CADisplayLink 每秒计数 ----
- (void)onTick:(CADisplayLink *)dl {
    _frames++;
    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval dt = now - _lastTs;
    if (dt >= 1.0) {
        _fps = (float)(_frames / dt);
        _frames = 0;
        _lastTs = now;
    }
}

// ---- CPU：host_cpu_load_info 两次采样差值 ----
- (void)sampleCpu {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    kern_return_t kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                                       (host_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return;

    if (_hasPrevCpu) {
        natural_t du = info.cpu_ticks[CPU_STATE_USER]   - _prevCpu.cpu_ticks[CPU_STATE_USER];
        natural_t ds = info.cpu_ticks[CPU_STATE_SYSTEM] - _prevCpu.cpu_ticks[CPU_STATE_SYSTEM];
        natural_t di = info.cpu_ticks[CPU_STATE_IDLE]   - _prevCpu.cpu_ticks[CPU_STATE_IDLE];
        natural_t dn = info.cpu_ticks[CPU_STATE_NICE]   - _prevCpu.cpu_ticks[CPU_STATE_NICE];
        natural_t total = du + ds + di + dn;
        if (total > 0)
            _cpuUsage = (float)(du + ds + dn) / (float)total * 100.0f;
    }
    _prevCpu = info;
    _hasPrevCpu = YES;
}

// ---- 内存：TASK_VM_INFO phys_footprint ----
- (float)memMB {
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count);
    if (kr != KERN_SUCCESS) return 0;
    return (float)vm.phys_footprint / (1024.0f * 1024.0f);
}

@end

// ============================================================
#pragma mark - 悬浮面板控制器（数据 + 抽屉开关）
// ============================================================

@interface PanelView : UIView
- (void)refreshWithMetrics:(Metrics *)m;
@end

@implementation PanelView {
    UILabel *_fpsVal, *_latVal, *_cpuVal, *_memVal, *_clockVal;
    UISwitch *_swFps, *_swCpu, *_swMem, *_swClock;
    UIView *_drawer;      // 抽屉容器（默认隐藏）
    BOOL _dragging;
    CGPoint _dragStart;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self build];
    return self;
}

// ---- 构建面板 ----
- (void)build {
    CGFloat w = self.bounds.size.width;

    self.layer.cornerRadius = 18;
    self.layer.masksToBounds = YES;

    // 毛玻璃背景
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:blur];
    bg.frame = self.bounds;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:bg];

    // 标题 + ⚙️ 按钮（右上角展开/收起抽屉）
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 180, 26)];
    title.text = @"⚡ GAME PANEL";
    title.textColor = [UIColor colorWithRed:0.4f green:0.8f blue:1.0f alpha:1];
    title.font = [UIFont boldSystemFontOfSize:14];
    [self addSubview:title];

    UIButton *gear = [UIButton buttonWithType:UIButtonTypeCustom];
    gear.frame = CGRectMake(w - 44, 6, 32, 32);
    [gear setTitle:@"⚙" forState:UIControlStateNormal];
    [gear setTitleColor:[UIColor colorWithWhite:1 alpha:0.85] forState:UIControlStateNormal];
    gear.titleLabel.font = [UIFont systemFontOfSize:18];
    [gear addTarget:self action:@selector(onGear:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:gear];

    // 监控数值行（上：数据）
    CGFloat y = 50;
    _fpsVal = [self addMetricRow:y     title:@"FPS"   unit:@""];
    _latVal = [self addMetricRow:y+32  title:@"延迟"  unit:@"ms"];
    _cpuVal = [self addMetricRow:y+64  title:@"CPU"   unit:@"%"];
    _memVal = [self addMetricRow:y+96  title:@"内存"  unit:@"MB"];

    // 时钟
    _clockVal = [self makeLabel:CGRectMake(14, y + 130, w - 28, 22)
                           text:@"--:--:--"
                          color:[UIColor colorWithWhite:1 alpha:0.55]
                           font:[UIFont fontWithName:@"Menlo" size:12]];
    [self addSubview:_clockVal];

    // 抽屉（默认隐藏，点 ⚙️ 展开）
    _drawer = [[UIView alloc] initWithFrame:CGRectMake(0, y + 158, w, 150)];
    _drawer.hidden = YES;
    [self addSubview:_drawer];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(14, 0, w - 28, 1)];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    [_drawer addSubview:line];

    _swFps   = [self addSwitchRow:14   title:@"FPS 显示"];
    _swCpu   = [self addSwitchRow:14+36 title:@"CPU 显示"];
    _swMem   = [self addSwitchRow:14+72 title:@"内存 显示"];
    _swClock = [self addSwitchRow:14+108 title:@"时钟 显示"];
    _swFps.on = _swCpu.on = _swMem.on = _swClock.on = YES;

    // 整个面板都可拖动（标题栏 + 数据区任意位置）
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(onPan:)];
    [self addGestureRecognizer:pan];
}

// 一行指标
- (UILabel *)addMetricRow:(CGFloat)y title:(NSString *)title unit:(NSString *)unit {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, self.bounds.size.width, 28)];
    [self addSubview:row];

    UILabel *name = [self makeLabel:CGRectMake(14, 4, 80, 20)
                               text:title
                              color:[UIColor colorWithWhite:1 alpha:0.65]
                               font:[UIFont systemFontOfSize:13]];
    [row addSubview:name];

    UILabel *val = [self makeLabel:CGRectMake(self.bounds.size.width - 150, 4, 136, 20)
                              text:@"--" unit:unit
                             color:[UIColor colorWithRed:0.3f green:1.0f blue:0.5f alpha:1]
                              font:[UIFont fontWithName:@"Menlo" size:15]];
    val.textAlignment = NSTextAlignmentRight;
    [row addSubview:val];
    return val;
}

// 一行开关（放抽屉里）
- (UISwitch *)addSwitchRow:(CGFloat)y title:(NSString *)title {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, self.bounds.size.width, 32)];
    [_drawer addSubview:row];

    UILabel *name = [self makeLabel:CGRectMake(14, 6, 200, 20)
                               text:title
                              color:[UIColor colorWithWhite:1 alpha:0.85]
                               font:[UIFont systemFontOfSize:13]];
    [row addSubview:name];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(self.bounds.size.width - 66, 2, 60, 32)];
    sw.onTintColor = [UIColor colorWithRed:0.2f green:0.7f blue:1.0f alpha:1];
    sw.transform = CGAffineTransformMakeScale(0.72, 0.72);
    [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
    return sw;
}

- (UILabel *)makeLabel:(CGRect)frame text:(NSString *)text color:(UIColor *)color font:(UIFont *)font {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.textColor = color;
    l.font = font;
    return l;
}
- (UILabel *)makeLabel:(CGRect)frame text:(NSString *)text unit:(NSString *)unit color:(UIColor *)color font:(UIFont *)font {
    UILabel *l = [self makeLabel:frame text:text color:color font:font];
    l.text = [text stringByAppendingString:unit];
    return l;
}

// ---- ⚙️ 按钮：展开/收起抽屉 ----
- (void)onGear:(id)sender {
    _drawer.hidden = !_drawer.hidden;
}

// ---- 整个面板拖动 ----
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *win = self.superview;
    if (!win) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        _dragStart = [g locationInView:win];
    } else if (g.state == UIGestureRecognizerStateChanged && _dragging) {
        CGPoint p = [g locationInView:win];
        CGPoint c = self.center;
        c.x += p.x - _dragStart.x;
        c.y += p.y - _dragStart.y;
        self.center = c;
        _dragStart = p;
    } else if (g.state == UIGestureRecognizerStateEnded) {
        _dragging = NO;
    }
}

// ---- 开关切换 ----
- (void)onSwitch:(UISwitch *)sw {
    if (sw == _swFps)   [self toggleRow:_fpsVal  on:sw.on];
    if (sw == _swCpu)   [self toggleRow:_cpuVal  on:sw.on];
    if (sw == _swMem)   [self toggleRow:_memVal  on:sw.on];
    if (sw == _swClock) _clockVal.hidden = !sw.on;
}

- (void)toggleRow:(UILabel *)val on:(BOOL)on {
    UIView *row = val.superview;
    row.hidden = !on;
}

// ---- 刷新数值 ----
- (void)refreshWithMetrics:(Metrics *)m {
    if (m.fps > 0 && !_swFps.hidden && _swFps.on)
        _fpsVal.text = [NSString stringWithFormat:@"%.1f", m.fps];
    _latVal.text = [NSString stringWithFormat:@"%.1f ms", m.fps > 0 ? 1000.0f / m.fps : 0];
    _cpuVal.text = [NSString stringWithFormat:@"%.1f %%", m.cpuUsage];
    _memVal.text = [NSString stringWithFormat:@"%.0f MB", [m memMB]];

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss";
    _clockVal.text = [df stringFromDate:[NSDate date]];
}

@end

// ============================================================
#pragma mark - 总控制器：悬浮球 + 面板 + 窗口
// ============================================================

@interface FpsOverlay : NSObject
@end

@implementation FpsOverlay {
    UIWindow *_window;
    UIButton *_ball;
    UIView *_panelWrap;
    PanelView *_panel;
    BOOL _panelShown;
}

// ---- 注入入口（+load 最早时机，等启动完成后挂载） ----
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(lcAppReady:)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([UIApplication sharedApplication].keyWindow)
                [self lcAppReady:nil];
        });
    });
}

+ (void)lcAppReady:(NSNotification *)n {
    static FpsOverlay *ov;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        ov = [FpsOverlay new];
        [ov setup];
        NSLog(@"[fpspanel] ✅ 悬浮面板已注入宿主: %@",
              [[NSBundle mainBundle] bundleIdentifier]);
    });
}

- (void)setup {
    // 独立高等级窗口（不抢 key window），OverlayWindow 实现触摸穿透
    _window = [[OverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _window.windowLevel = UIWindowLevelStatusBar + 1;

    // 空 rootViewController（满足 iOS 启动断言）
    UIViewController *rootVC = [UIViewController new];
    _window.rootViewController = rootVC;
    _window.hidden = NO;

    // 悬浮球（60x60 圆角，中央实时 FPS）
    _ball = [UIButton buttonWithType:UIButtonTypeCustom];
    _ball.frame = CGRectMake(20, 120, 60, 60);
    _ball.layer.cornerRadius = 30;
    _ball.layer.borderWidth = 1;
    _ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _ball.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
    [_ball setTitle:@"FPS" forState:UIControlStateNormal];
    [_ball setTitleColor:[UIColor colorWithRed:0.3f green:1.0f blue:0.5f alpha:1]
                forState:UIControlStateNormal];
    _ball.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [_ball addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    // 悬浮球也可拖动
    UIPanGestureRecognizer *ballPan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(ballDragged:)];
    [_ball addGestureRecognizer:ballPan];

    [rootVC.view addSubview:_ball];

    // 面板（默认收起，点悬浮球展开）
    _panelWrap = [[UIView alloc] initWithFrame:CGRectMake(16, 160, 300, 320)];
    _panelWrap.hidden = YES;
    _panel = [[PanelView alloc] initWithFrame:_panelWrap.bounds];
    [_panelWrap addSubview:_panel];
    [rootVC.view addSubview:_panelWrap];

    // 每秒刷新一次监控数值
    [[Metrics shared] start];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                   selector:@selector(refresh)
                                   userInfo:nil repeats:YES];
}

- (void)refresh {
    [_panel refreshWithMetrics:[Metrics shared]];
    // 悬浮球上显示实时 FPS
    Metrics *m = [Metrics shared];
    if (m.fps > 0)
        [_ball setTitle:[NSString stringWithFormat:@"%.0f", m.fps] forState:UIControlStateNormal];
}

- (void)togglePanel {
    _panelShown = !_panelShown;
    [UIView animateWithDuration:0.22 animations:^{
        _panelWrap.hidden = !_panelShown;
        _panelWrap.alpha = _panelShown ? 1 : 0;
    }];
}

- (void)ballDragged:(UIPanGestureRecognizer *)g {
    UIView *win = _ball.superview;
    if (!win) return;
    if (g.state == UIGestureRecognizerStateBegan ||
        g.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [g locationInView:win];
        CGPoint c = _ball.center;
        c.x = MAX(40, MIN(win.bounds.size.width - 40, p.x));
        c.y = MAX(40, MIN(win.bounds.size.height - 40, p.y));
        _ball.center = c;
    }
}

@end
