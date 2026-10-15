//
//  FpsPanel.m — 专业游戏监控悬浮窗（standalone 注入 dylib）
//
//  免越狱注入（Sideloadly / 证书直签 / LiveContainer+ElleKit 均可）。
//  实现：直接挂载到游戏主窗口（keyWindow）。
//  交互：悬浮球可拖动/点击；面板与悬浮球绑定，拖动时面板跟随移动；
//        无设置键/无开关，全部数据直接显示。
//  数据：FPS / 延迟 / CPU / 内存 / 电量 / 机型 / 分辨率 / 时间。
//  纯 ObjC Runtime + 公开 API，不依赖 Substrate/ElleKit。
//
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>

// ============================================================
#pragma mark - 监控数据采集
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

// ---- FPS ----
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

// ---- CPU ----
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

// ---- 内存 ----
- (float)memMB {
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count);
    if (kr != KERN_SUCCESS) return 0;
    return (float)vm.phys_footprint / (1024.0f * 1024.0f);
}

// ---- 电量 ----
- (float)batteryPercent {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float lvl = [UIDevice currentDevice].batteryLevel;
    if (lvl < 0) return -1;
    return lvl * 100.0f;
}

// ---- 机型代号 ----
- (NSString *)deviceModel {
    char buf[128];
    size_t len = sizeof(buf);
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) == 0)
        return [NSString stringWithUTF8String:buf];
    return @"unknown";
}

// ---- 分辨率（像素）----
- (NSString *)screenRes {
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat sc = [UIScreen mainScreen].scale;
    return [NSString stringWithFormat:@"%.0f×%.0f", s.width * sc, s.height * sc];
}

@end

// ============================================================
#pragma mark - 悬浮面板（全部数据直接显示，无设置键/开关）
// ============================================================

@interface PanelView : UIView
- (void)refreshWithMetrics:(Metrics *)m;
@end

@implementation PanelView {
    UILabel *_fpsVal, *_latVal, *_cpuVal, *_memVal, *_batVal, *_devVal, *_resVal, *_timeVal;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self build];
    return self;
}

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

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 260, 24)];
    title.text = @"⚡ GAME PANEL";
    title.textColor = [UIColor colorWithRed:0.4f green:0.8f blue:1.0f alpha:1];
    title.font = [UIFont boldSystemFontOfSize:14];
    [self addSubview:title];

    // 8 行数据（全部显示）
    CGFloat y = 46;
    _fpsVal  = [self addMetricRow:y      title:@"FPS"     unit:@""];
    _latVal  = [self addMetricRow:y+30   title:@"延迟"    unit:@"ms"];
    _cpuVal  = [self addMetricRow:y+60   title:@"CPU"     unit:@"%"];
    _memVal  = [self addMetricRow:y+90   title:@"内存"    unit:@"MB"];
    _batVal  = [self addMetricRow:y+120  title:@"电量"    unit:@"%"];
    _devVal  = [self addMetricRow:y+150  title:@"机型"    unit:@""];
    _resVal  = [self addMetricRow:y+180  title:@"分辨率"  unit:@""];
    _timeVal = [self addMetricRow:y+210  title:@"时间"    unit:@""];
}

// 一行指标
- (UILabel *)addMetricRow:(CGFloat)y title:(NSString *)title unit:(NSString *)unit {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, self.bounds.size.width, 28)];
    [self addSubview:row];

    UILabel *name = [self makeLabel:CGRectMake(14, 4, 90, 20)
                               text:title
                              color:[UIColor colorWithWhite:1 alpha:0.65]
                               font:[UIFont systemFontOfSize:13]];
    [row addSubview:name];

    UILabel *val = [self makeLabel:CGRectMake(self.bounds.size.width - 170, 4, 156, 20)
                              text:@"--" unit:unit
                             color:[UIColor colorWithRed:0.3f green:1.0f blue:0.5f alpha:1]
                              font:[UIFont fontWithName:@"Menlo" size:14]];
    val.textAlignment = NSTextAlignmentRight;
    [row addSubview:val];
    return val;
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

// ---- 刷新 ----
- (void)refreshWithMetrics:(Metrics *)m {
    if (m.fps > 0)
        _fpsVal.text = [NSString stringWithFormat:@"%.1f", m.fps];
    _latVal.text = [NSString stringWithFormat:@"%.1f ms", m.fps > 0 ? 1000.0f / m.fps : 0];
    _cpuVal.text = [NSString stringWithFormat:@"%.1f %%", m.cpuUsage];
    _memVal.text = [NSString stringWithFormat:@"%.0f MB", [m memMB]];

    float bat = [m batteryPercent];
    _batVal.text = bat < 0 ? @"--" : [NSString stringWithFormat:@"%.0f %%", bat];
    _devVal.text = [m deviceModel];
    _resVal.text = [m screenRes];

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"MM-dd HH:mm:ss";
    _timeVal.text = [df stringFromDate:[NSDate date]];
}

@end

// ============================================================
#pragma mark - 总控制器：悬浮球 + 绑定面板
// ============================================================

@interface FpsOverlay : NSObject
@end

@implementation FpsOverlay {
    UIWindow *_hostWindow;
    UIButton *_ball;
    UIView *_panelWrap;
    PanelView *_panel;
    BOOL _panelShown;
}

// ---- 注入入口 ----
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
    _hostWindow = [UIApplication sharedApplication].keyWindow;
    if (!_hostWindow)
        _hostWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!_hostWindow) return;

    // 悬浮球
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

    // 悬浮球拖动（面板跟随）
    UIPanGestureRecognizer *ballPan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(ballDragged:)];
    [_ball addGestureRecognizer:ballPan];

    [_hostWindow addSubview:_ball];

    // 面板（初始隐藏，位置由 layoutPanel 按悬浮球定位）
    _panelWrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 300)];
    _panelWrap.hidden = YES;
    _panel = [[PanelView alloc] initWithFrame:_panelWrap.bounds];
    [_panelWrap addSubview:_panel];
    [_hostWindow addSubview:_panelWrap];

    [[Metrics shared] start];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                   selector:@selector(refresh)
                                   userInfo:nil repeats:YES];
}

// ---- 面板跟随悬浮球定位（右侧优先，放不下翻到左侧，并夹在屏幕内）----
- (void)layoutPanel {
    CGRect b = _ball.frame;
    CGFloat pw = 300, ph = 300;
    CGFloat x = b.origin.x + b.size.width + 8;
    if (x + pw > _hostWindow.bounds.size.width - 8)
        x = b.origin.x - pw - 8;               // 右侧放不下 → 放左边
    CGFloat y = b.origin.y - 10;
    if (y < 20) y = 20;
    if (y + ph > _hostWindow.bounds.size.height - 20)
        y = _hostWindow.bounds.size.height - ph - 20;
    _panelWrap.frame = CGRectMake(x, y, pw, ph);
}

- (void)refresh {
    [_panel refreshWithMetrics:[Metrics shared]];
    Metrics *m = [Metrics shared];
    if (m.fps > 0)
        [_ball setTitle:[NSString stringWithFormat:@"%.0f", m.fps] forState:UIControlStateNormal];
}

- (void)togglePanel {
    _panelShown = !_panelShown;
    if (_panelShown) [self layoutPanel];
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
        [self layoutPanel];   // 面板跟着球走
    }
}

@end
