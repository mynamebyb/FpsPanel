//
//  FpsPanel.m — 专业游戏监控悬浮窗（standalone 注入 dylib）
//
//  免越狱注入（Sideloadly / 证书直签 / LiveContainer+ElleKit 均可）。
//  实现：直接挂载到游戏主窗口（keyWindow）——Unity 悬浮窗插件标准做法。
//  交互：悬浮球可拖动/点击开面板；面板固定不拖动（避免手势抢点击）；
//        ⚙️ 展开/收起开关抽屉。
//  数据：FPS / 延迟 / CPU / 内存 / 电量 / 机型 / 分辨率 / 日期时间。
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
    if (lvl < 0) return -1;   // 模拟器/未知
    return lvl * 100.0f;
}

// ---- 机型代号（iPhone11,8 等）----
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
#pragma mark - 悬浮面板控制器（8 行数据 + 抽屉开关）
// ============================================================

@interface PanelView : UIView
- (void)refreshWithMetrics:(Metrics *)m;
@end

@implementation PanelView {
    UILabel *_fpsVal, *_latVal, *_cpuVal, *_memVal, *_batVal, *_devVal, *_resVal, *_timeVal;
    UISwitch *_swFps, *_swCpu, *_swMem, *_swClock;
    UIView *_drawer;
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

    // 标题 + ⚙️
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 200, 24)];
    title.text = @"⚡ GAME PANEL";
    title.textColor = [UIColor colorWithRed:0.4f green:0.8f blue:1.0f alpha:1];
    title.font = [UIFont boldSystemFontOfSize:14];
    [self addSubview:title];

    UIButton *gear = [UIButton buttonWithType:UIButtonTypeCustom];
    gear.frame = CGRectMake(w - 48, 6, 40, 40);   // 放大点击区域
    [gear setTitle:@"⚙" forState:UIControlStateNormal];
    [gear setTitleColor:[UIColor colorWithWhite:1 alpha:0.9] forState:UIControlStateNormal];
    gear.titleLabel.font = [UIFont systemFontOfSize:20];
    [gear addTarget:self action:@selector(onGear:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:gear];

    // 8 行数据
    CGFloat y = 46;
    _fpsVal = [self addMetricRow:y      title:@"FPS"    unit:@""];
    _latVal = [self addMetricRow:y+30   title:@"延迟"   unit:@"ms"];
    _cpuVal = [self addMetricRow:y+60   title:@"CPU"    unit:@"%"];
    _memVal = [self addMetricRow:y+90   title:@"内存"   unit:@"MB"];
    _batVal = [self addMetricRow:y+120  title:@"电量"   unit:@"%"];
    _devVal = [self addMetricRow:y+150  title:@"机型"   unit:@""];
    _resVal = [self addMetricRow:y+180  title:@"分辨率" unit:@""];
    _timeVal = [self addMetricRow:y+210 title:@"时间"   unit:@""];

    // 抽屉（默认隐藏）
    _drawer = [[UIView alloc] initWithFrame:CGRectMake(0, y + 244, w, 158)];
    _drawer.hidden = YES;
    [self addSubview:_drawer];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(14, 0, w - 28, 1)];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    [_drawer addSubview:line];

    _swFps   = [self addSwitchRow:14     title:@"FPS 显示"];
    _swCpu   = [self addSwitchRow:14+36  title:@"CPU 显示"];
    _swMem   = [self addSwitchRow:14+72  title:@"内存 显示"];
    _swClock = [self addSwitchRow:14+108 title:@"时间 显示"];
    _swFps.on = _swCpu.on = _swMem.on = _swClock.on = YES;
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

// 一行开关
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

// ---- ⚙️ 展开/收起抽屉 ----
- (void)onGear:(id)sender {
    _drawer.hidden = !_drawer.hidden;
}

// ---- 开关 ----
- (void)onSwitch:(UISwitch *)sw {
    if (sw == _swFps)   [self toggleRow:_fpsVal  on:sw.on];
    if (sw == _swCpu)   [self toggleRow:_cpuVal  on:sw.on];
    if (sw == _swMem)   [self toggleRow:_memVal  on:sw.on];
    if (sw == _swClock) _timeVal.hidden = !sw.on;
}

- (void)toggleRow:(UILabel *)val on:(BOOL)on {
    UIView *row = val.superview;
    row.hidden = !on;
}

// ---- 刷新 ----
- (void)refreshWithMetrics:(Metrics *)m {
    if (m.fps > 0 && !_swFps.hidden && _swFps.on)
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
#pragma mark - 总控制器：悬浮球 + 面板（挂载到游戏主窗口）
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

    // 悬浮球（可拖可点）
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

    UIPanGestureRecognizer *ballPan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(ballDragged:)];
    [_ball addGestureRecognizer:ballPan];

    [_hostWindow addSubview:_ball];

    // 面板（固定位置，不参与拖动；高 470 容纳 8 行数据 + 抽屉）
    _panelWrap = [[UIView alloc] initWithFrame:CGRectMake(16, 160, 300, 470)];
    _panelWrap.hidden = YES;
    _panel = [[PanelView alloc] initWithFrame:_panelWrap.bounds];
    [_panelWrap addSubview:_panel];
    [_hostWindow addSubview:_panelWrap];

    [[Metrics shared] start];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                   selector:@selector(refresh)
                                   userInfo:nil repeats:YES];
}

- (void)refresh {
    [_panel refreshWithMetrics:[Metrics shared]];
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
