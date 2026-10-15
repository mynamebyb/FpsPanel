# FpsPanel — 专业游戏监控悬浮窗（iOS 注入 dylib）

免越狱注入（Sideloadly / 证书直签 / LiveContainer+ElleKit 均可）。
注入后屏幕出现可拖动的悬浮球，点击展开毛玻璃监控面板。

## 功能
- **悬浮球**：实时显示 FPS，可拖动到屏幕任意位置
- **毛玻璃面板**：点击悬浮球展开/收起
- **实时监控**（每秒刷新）：
  - FPS（帧率）
  - 延迟（帧耗时 ms，由 FPS 换算）
  - CPU 占用（%）
  - 内存占用（MB）
  - 时钟（HH:mm:ss）
- **独立开关**：FPS / CPU / 内存 / 时钟 四项可单独开/关
- 深色毛玻璃 UI（UIBlurEffect）+ Menlo 等宽数字，绿字电竞风

## 编译（GitHub Actions 云端，Windows 也能出 dylib）
1. 新建一个 GitHub 仓库，把本工程文件（Makefile、src/、.github/）上传到仓库根
2. 仓库 Actions 页会自动构建（macos runner 装 Theos 编译）
3. 跑完下载 **FpsPanel-dylib** 产物 = 成品 dylib

> 本地编译需 macOS + Theos：`make clean && make`，产物 `.theos/obj/debug/FpsPanel.dylib`

## 注入方式
- **Sideloadly / 证书直签**：注入 IPA 时选 `FpsPanel.dylib`
- **LiveContainer**：dylib 放 Tweaks 目录 → 开 ElleKit → 游戏内勾选启用

## 验证注入
设备日志过滤 `fpspanel`，看到：
```
[fpspanel] ✅ 悬浮面板已注入宿主: com.xxx.game
```
即生效。屏幕左上角会出现悬浮球。

## 技术要点（纯 ObjC Runtime，无 Substrate）
- `+load` + `UIApplicationDidFinishLaunchingNotification` 等启动完成后挂载
- 独立 `UIWindow`，`windowLevel = UIWindowLevelStatusBar + 1`，不抢 key window
- FPS：`CADisplayLink` 计数
- CPU：`host_statistics(HOST_CPU_LOAD_INFO)` 两次采样差值
- 内存：`task_info(TASK_VM_INFO)` 的 `phys_footprint`
- UI 全代码构建（无 xib），`UIBlurEffect` 毛玻璃 + `UIPanGestureRecognizer` 拖动

## 风险提示
- 悬浮窗会覆盖在游戏画面上，属于注入行为；联机游戏有反作弊检测，**账号封禁风险自担**
- 此 dylib 不做任何游戏数据修改，仅 UI 监控（装逼向），但注入环境本身仍可能被检测
