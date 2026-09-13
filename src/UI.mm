#import "AZGPS.h"
#import "UI.h"
#import "Audit.h"
#import "Identity.h"

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
#import <cmath>
#import <objc/runtime.h>

static char AZBaseFrameKey, AZButtonKey;
static NSString *const AZLayoutPrefsKey=@"AZ.GPS.ui.layout";
static NSString *const AZAppearancePrefsKey=@"AZ.GPS.ui.appearance";

#pragma mark - Root

@interface AZOverlayWindow : UIWindow
@end

@implementation AZOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {

    UIView *hit = [super hitTest:point withEvent:event];

    // If the window/root itself is the only hit target, do not consume
    // the touch. Returning nil here lets the event continue to the
    // application's normal window underneath AZGPS.
    if (hit == nil ||
        hit == self ||
        hit == self.rootViewController.view) {
        return nil;
    }

    return hit;
}

@end


@interface AZOverlayPassthroughView : UIView
@end

@implementation AZOverlayPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {

    UIView *hit = [super hitTest:point withEvent:event];

    // If the touch lands only on the transparent full-screen root,
    // pass it through to the host application below AZGPS.
    if (hit == self) {
        return nil;
    }

    // AZGPS controls such as the floating button and open panel
    // continue receiving touches normally.
    return hit;
}

@end


@interface AZOverlayRootController : UIViewController
@end

@implementation AZOverlayRootController

- (void)loadView {

    AZOverlayPassthroughView *v =
        [[AZOverlayPassthroughView alloc]
            initWithFrame:UIScreen.mainScreen.bounds];

    v.backgroundColor = UIColor.clearColor;
    v.userInteractionEnabled = YES;

    self.view = v;
}

@end

#pragma mark - UI

@interface AZUIController () <MKMapViewDelegate, UISearchBarDelegate>
@end

@implementation AZUIController {
    UIWindow *_overlayWindow;
    UIButton *_floatingButton;
    UIScrollView *_panel;
    UIView *_content;

    UISearchBar *_searchBar;
    MKMapView *_mapView;
    UILabel *_coordLabel;
    UILabel *_statusLabel;
    UISwitch *_locationSwitch;
    UISwitch *_photoSwitch;

    CLLocationCoordinate2D _selectedCoordinate;
    BOOL _hasCoordinate;
    NSTimer *_statusTimer;
    NSMutableArray<NSDictionary *> *_customButtons;
    MKPointAnnotation *_movementPin;
}

+ (instancetype)sharedController {
    static AZUIController *obj;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        obj = [[AZUIController alloc] init];
    });
    return obj;
}

+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[AZUIController sharedController] installWhenReady];
    });
}

- (void)installWhenReady {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installOverlay];
    });
}

- (UIWindowScene *)activeScene API_AVAILABLE(ios(13.0)) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

- (void)installOverlay {
    if (_overlayWindow) {
        _overlayWindow.hidden = NO;
        return;
    }

    AZOverlayWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeScene];
        if (!scene) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                [self installOverlay];
            });
            return;
        }
        w = [[AZOverlayWindow alloc] initWithWindowScene:scene];
    } else {
        w = [[AZOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }

    w.frame = UIScreen.mainScreen.bounds;
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelAlert + 1000.0;

    AZOverlayRootController *root = [[AZOverlayRootController alloc] init];
    w.rootViewController = root;
    w.hidden = NO;
    _overlayWindow = w;

    [self buildFloatingButton:root.view];
    _statusTimer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer){[self refreshStatus];}];
    [[NSRunLoop mainRunLoop]addTimer:_statusTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - Helpers

- (UIColor *)panelColor {
    return [UIColor colorWithRed:0.105 green:0.11 blue:0.12 alpha:0.985];
}

- (UIColor *)cardColor {
    return [UIColor colorWithRed:0.19 green:0.20 blue:0.21 alpha:0.98];
}

- (UILabel *)label:(NSString *)text frame:(CGRect)frame size:(CGFloat)size bold:(BOOL)bold {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.textColor = UIColor.whiteColor;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    return l;
}

- (UIButton *)button:(NSString *)title frame:(CGRect)frame tint:(UIColor *)tint {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    b.layer.cornerRadius = 13.0;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [tint colorWithAlphaComponent:0.65].CGColor;
    b.backgroundColor = [tint colorWithAlphaComponent:0.23];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.78;
    return b;
}

- (UIView *)card:(CGRect)frame {
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = [self cardColor];
    v.layer.cornerRadius = 16.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    return v;
}

#pragma mark - Floating

- (void)buildFloatingButton:(UIView *)root {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(18, 160, 62, 62);
    b.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.10 alpha:0.98];
    b.layer.cornerRadius = 31;
    b.layer.borderWidth = 2;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    b.layer.shadowOpacity = 0.35;
    b.layer.shadowRadius = 8;
    [b setTitle:@"\U0001F98A" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:29];
    [b addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragFloating:)];
    [b addGestureRecognizer:pan];

    [root addSubview:b];
    _floatingButton = b;
    [b addGestureRecognizer:[[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(customizationLongPress:)]];
    [self applyFloatingPreferences];
}

- (void)dragFloating:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    UIView *p = v.superview;
    CGPoint t = [g translationInView:p];
    CGPoint c = v.center;
    c.x += t.x;
    c.y += t.y;
    CGFloat hw = CGRectGetWidth(v.bounds)/2.0;
    CGFloat hh = CGRectGetHeight(v.bounds)/2.0;
    c.x = MAX(hw, MIN(CGRectGetWidth(p.bounds)-hw, c.x));
    c.y = MAX(hh, MIN(CGRectGetHeight(p.bounds)-hh, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:p];
    if(g.state==UIGestureRecognizerStateEnded){NSMutableDictionary *prefs=[[self appearancePreferences]mutableCopy];prefs[@"x"]=@(v.center.x/MAX(1.0,CGRectGetWidth(p.bounds)));prefs[@"y"]=@(v.center.y/MAX(1.0,CGRectGetHeight(p.bounds)));[NSUserDefaults.standardUserDefaults setObject:prefs forKey:AZAppearancePrefsKey];}
}

#pragma mark - Panel

- (void)togglePanel {
    if (_panel) [self closePanel];
    else [self buildPanel];
}

- (void)buildPanel {
    UIView *root = _overlayWindow.rootViewController.view;
    if (!root) return;

    CGFloat sw = CGRectGetWidth(root.bounds);
    CGFloat sh = CGRectGetHeight(root.bounds);
    CGFloat pw = MIN(376.0, sw - 34.0);
    CGFloat ph = MIN(820.0, sh - 42.0);
    CGFloat px = (sw-pw)/2.0;
    CGFloat py = MAX(18.0, (sh-ph)/2.0);

    UIScrollView *panel = [[UIScrollView alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    panel.backgroundColor = [self panelColor];
    panel.layer.cornerRadius = 28;
    panel.layer.masksToBounds = YES;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    panel.showsVerticalScrollIndicator = NO;

    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0,0,pw,1125)];
    [panel addSubview:content];
    panel.contentSize = content.bounds.size;

    [root addSubview:panel];
    _panel = panel;
    _content = content;
    _floatingButton.hidden = YES;

    CGFloat W = pw;
    CGFloat margin = 14;
    CGFloat inner = W - margin*2;

    // Header
    UILabel *logo = [self label:@"\U0001F98A  AZ.GPS" frame:CGRectMake(18,14,178,36) size:24 bold:YES];
    [content addSubview:logo];

    UILabel *sub = [self label:@"GPS baseline • iOS 12+" frame:CGRectMake(70,44,180,18) size:11 bold:NO];
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    [content addSubview:sub];

    UIButton *support = [self button:@"\u2708\uFE0E  \u0627\u0644\u062F\u0639\u0645" frame:CGRectMake(W-166,12,92,40)
                                tint:[UIColor colorWithRed:0.0 green:0.68 blue:0.92 alpha:1]];
    [support addTarget:self action:@selector(showSupport) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:support];

    UIButton *info = [UIButton buttonWithType:UIButtonTypeSystem];
    info.frame = CGRectMake(W-70,13,38,38);
    info.backgroundColor = [UIColor colorWithRed:0.16 green:0.76 blue:0.29 alpha:1];
    info.layer.cornerRadius = 19;
    [info setTitle:@"\u24D8" forState:UIControlStateNormal];
    [info setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    info.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [info addTarget:self action:@selector(showStatus) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:info];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(W-34,14,28,34);
    [close setTitle:@"\u00D7" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:.65] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:30];
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:close];

    // Search
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(margin,68,inner,48)];
    _searchBar.delegate = self;
    _searchBar.placeholder = @"\u0628\u062D\u062B \u0639\u0646 \u0645\u0648\u0642\u0639";
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.barStyle = UIBarStyleBlack;
    [content addSubview:_searchBar];

    // Save row
    UIColor *orange = [UIColor colorWithRed:.95 green:.55 blue:.0 alpha:1];
    UIColor *green  = [UIColor colorWithRed:.10 green:.72 blue:.30 alpha:1];
    UIColor *red    = [UIColor colorWithRed:.92 green:.23 blue:.20 alpha:1];
    UIColor *cyan   = [UIColor colorWithRed:.0 green:.72 blue:.88 alpha:1];
    UIColor *teal   = [UIColor colorWithRed:.08 green:.72 blue:.62 alpha:1];
    UIColor *purple = [UIColor colorWithRed:.58 green:.31 blue:.92 alpha:1];

    CGFloat gap=8, third=(inner-gap*2)/3.0;
    UIButton *saved=[self button:@"\U0001F516 \u0627\u0644\u0645\u062D\u0641\u0648\u0638\u0627\u062A" frame:CGRectMake(margin,124,third,48) tint:orange];
    UIButton *save=[self button:@"\u271A  \u062D\u0641\u0638" frame:CGRectMake(margin+third+gap,124,third,48) tint:green];
    UIButton *restore=[self button:@"\u21B6  \u0627\u0633\u062A\u0639\u0627\u062F\u0629" frame:CGRectMake(margin+(third+gap)*2,124,third,48) tint:red];
    [saved addTarget:self action:@selector(showSaved) forControlEvents:UIControlEventTouchUpInside];
    [save addTarget:self action:@selector(saveCurrent) forControlEvents:UIControlEventTouchUpInside];
    [restore addTarget:self action:@selector(restoreLocation) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:saved]; [content addSubview:save]; [content addSubview:restore];

    // Map
    _mapView = [[MKMapView alloc] initWithFrame:CGRectMake(margin,184,inner,224)];
    _mapView.delegate = self;
    _mapView.layer.cornerRadius = 18;
    _mapView.layer.masksToBounds = YES;
    _mapView.showsUserLocation = YES;
    [content addSubview:_mapView];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(mapLongPress:)];
    lp.minimumPressDuration = .3;
    [_mapView addGestureRecognizer:lp];

    UIButton *expand=[self button:@"\u2922" frame:CGRectMake(W-68,198,40,40)
                             tint:[UIColor colorWithWhite:.7 alpha:1]];
    [expand addTarget:self action:@selector(centerSelected) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:expand];

    AZRuntimeState *state=[AZRuntimeState sharedState];
    CLLocationCoordinate2D start = state.locationEnabled ? CLLocationCoordinate2DMake(state.currentLatitude,state.currentLongitude) : CLLocationCoordinate2DMake(24.7136,46.6753);
    [self selectCoordinate:start animated:NO];

    // Map mode row
    UISegmentedControl *mapModes =
        [[UISegmentedControl alloc] initWithItems:@[@"\u0639\u0627\u062F\u064A",@"\u0642\u0645\u0631 \u0635\u0646\u0627\u0639\u064A"]];
    mapModes.frame = CGRectMake(margin,418,inner*0.50-4,42);
    mapModes.selectedSegmentIndex = 0;
    [mapModes addTarget:self action:@selector(mapModeChanged:) forControlEvents:UIControlEventValueChanged];
    [content addSubview:mapModes];

    UIButton *myLocation=[self button:@"\u27A4  \u0645\u0648\u0642\u0639\u064A"
                                frame:CGRectMake(margin+inner*0.50+4,418,inner*0.50-4,42)
                                 tint:cyan];
    [myLocation addTarget:self action:@selector(goMyLocation) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:myLocation];

    // Location switch
    UIView *locCard=[self card:CGRectMake(margin,472,inner,60)];
    [content addSubview:locCard];
    UILabel *locTitle=[self label:@"\u27A4  \u062A\u0641\u0639\u064A\u0644 \u062A\u063A\u064A\u064A\u0631 \u0627\u0644\u0645\u0648\u0642\u0639"
                            frame:CGRectMake(18,8,inner-95,42) size:17 bold:NO];
    [locCard addSubview:locTitle];
    _locationSwitch=[[UISwitch alloc] initWithFrame:CGRectMake(inner-68,13,55,32)];
    [_locationSwitch addTarget:self action:@selector(locationSwitchChanged:)
              forControlEvents:UIControlEventValueChanged];
    [locCard addSubview:_locationSwitch];

    _coordLabel=[self label:@"" frame:CGRectMake(margin,537,inner,20) size:11 bold:NO];
    _coordLabel.textAlignment=NSTextAlignmentCenter;
    _coordLabel.textColor=[UIColor colorWithWhite:1 alpha:.55];
    [content addSubview:_coordLabel];
    [self refreshCoordinate];

    // Route/random/schedule
    UIButton *route=[self button:@"\u2301  \u0645\u0633\u0627\u0631" frame:CGRectMake(margin,563,third,50) tint:teal];
    UIButton *random=[self button:@"\u2928  \u0639\u0634\u0648\u0627\u0626\u064A" frame:CGRectMake(margin+third+gap,563,third,50) tint:purple];
    UIButton *schedule=[self button:@"\u25F7  \u0627\u0644\u062C\u062F\u0648\u0644\u0629" frame:CGRectMake(margin+(third+gap)*2,563,third,50) tint:cyan];
    [route addTarget:self action:@selector(routeTapped) forControlEvents:UIControlEventTouchUpInside];
    [random addTarget:self action:@selector(randomTapped) forControlEvents:UIControlEventTouchUpInside];
    [schedule addTarget:self action:@selector(scheduleTapped) forControlEvents:UIControlEventTouchUpInside];
    
    [content addSubview:route]; [content addSubview:random]; [content addSubview:schedule];

    // Alternate photo card
    UIView *photoCard=[self card:CGRectMake(margin,625,inner,112)];
    [content addSubview:photoCard];
    UILabel *photoTitle=[self label:@"\U0001F4F7  \u0635\u0648\u0631\u0629 \u0628\u062F\u064A\u0644\u0629" frame:CGRectMake(16,8,180,38) size:17 bold:NO];
    [photoCard addSubview:photoTitle];
    _photoSwitch=[[UISwitch alloc] initWithFrame:CGRectMake(inner-68,12,55,32)];
    _photoSwitch.enabled=NO;
    [photoCard addSubview:_photoSwitch];

    CGFloat pGap=8, pW=(inner-32-pGap*2)/3.0;
    UIButton *flip=[self button:@"\u0639\u0643\u0633" frame:CGRectMake(16,57,pW,38) tint:teal];
    UIButton *upload=[self button:@"\u0631\u0641\u0639" frame:CGRectMake(16+pW+pGap,57,pW,38) tint:orange];
    UIButton *del=[self button:@"\u062D\u0630\u0641" frame:CGRectMake(16+(pW+pGap)*2,57,pW,38) tint:red];
    [flip addTarget:self action:@selector(notImplemented) forControlEvents:UIControlEventTouchUpInside];
    [upload addTarget:self action:@selector(notImplemented) forControlEvents:UIControlEventTouchUpInside];
    [del addTarget:self action:@selector(notImplemented) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton *pending in @[flip,upload,del]) { pending.enabled=NO; pending.alpha=0.4; }
    [photoCard addSubview:flip]; [photoCard addSubview:upload]; [photoCard addSubview:del];

    // Bluetooth / WiFi
    CGFloat half=(inner-gap)/2.0;
    UIButton *bt=[self button:@"\u25C9))) \u0627\u0644\u0628\u0644\u0648\u062A\u0648\u062B" frame:CGRectMake(margin,750,half,50)
                        tint:[UIColor colorWithRed:.1 green:.58 blue:.9 alpha:1]];
    UIButton *wifi=[self button:@"\u2301  \u0627\u0644\u0648\u0627\u064A \u0641\u0627\u064A" frame:CGRectMake(margin+half+gap,750,half,50) tint:cyan];
    [bt addTarget:self action:@selector(bluetoothTapped) forControlEvents:UIControlEventTouchUpInside];
    [wifi addTarget:self action:@selector(wifiTapped) forControlEvents:UIControlEventTouchUpInside];
    bt.enabled=NO;wifi.enabled=NO;bt.alpha=0.4;wifi.alpha=0.4;
    [content addSubview:bt]; [content addSubview:wifi];

    // Device card
    UIView *device=[self card:CGRectMake(margin,812,inner,66)];
    [content addSubview:device];
    UILabel *deviceTitle=[self label:@"\U0001F4F1  \u0645\u0639\u0631\u0641 \u0627\u0644\u062C\u0647\u0627\u0632" frame:CGRectMake(15,10,145,42) size:16 bold:NO];
    [device addSubview:deviceTitle];

    NSArray *deviceButtons=@[@"\u0646\u0633\u062E",@"\u062A\u0639\u0628\u0626\u0629",@"\u0647\u0648\u064A\u0629",@"\u0627\u0633\u062A\u0639\u0627\u062F\u0629"];
    NSArray *deviceColors=@[orange,cyan,purple,green];
    CGFloat dW=(inner-170)/4.0;
    for (NSInteger i=0;i<4;i++) {
        UIButton *b=[self button:deviceButtons[i]
                          frame:CGRectMake(160+i*dW,13,dW-4,38)
                           tint:deviceColors[i]];
        [b addTarget:self action:@selector(deviceAction:) forControlEvents:UIControlEventTouchUpInside];
        b.tag=i;
        [device addSubview:b];
    }

    // Support / shop
    UIButton *shop=[self button:@"\U0001F6D2  \u0634\u0631\u0627\u0621 \u0643\u0648\u062F" frame:CGRectMake(margin,892,half,52) tint:orange];
    UIButton *chat=[self button:@"\u25CF  \u0627\u0644\u062F\u0639\u0645 \u0627\u0644\u0641\u0646\u064A" frame:CGRectMake(margin+half+gap,892,half,52) tint:cyan];
    [shop addTarget:self action:@selector(showSupport) forControlEvents:UIControlEventTouchUpInside];
    [chat addTarget:self action:@selector(showSupport) forControlEvents:UIControlEventTouchUpInside];
    shop.enabled=NO;chat.enabled=NO;shop.alpha=0.4;chat.alpha=0.4;
    [content addSubview:shop]; [content addSubview:chat];

    // Bottom controls
    UIButton *stop=[self button:@"\u23F9  \u0625\u064A\u0642\u0627\u0641 \u0627\u0644\u0643\u0644" frame:CGRectMake(margin,958,third,50) tint:red];
    UIButton *hide=[self button:@"\u25C9\u0338  \u0625\u062E\u0641\u0627\u0621 \u0627\u0644\u0623\u062F\u0627\u0629" frame:CGRectMake(margin+third+gap,958,third,50)
                           tint:[UIColor colorWithWhite:.65 alpha:1]];
    UIButton *custom=[self button:@"\u2637  \u062A\u062E\u0635\u064A\u0635" frame:CGRectMake(margin+(third+gap)*2,958,third,50) tint:cyan];
    [stop addTarget:self action:@selector(stopAll) forControlEvents:UIControlEventTouchUpInside];
    [hide addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [custom addTarget:self action:@selector(showCustomization) forControlEvents:UIControlEventTouchUpInside];
    
    [content addSubview:stop]; [content addSubview:hide]; [content addSubview:custom];

    UIButton *logs=[self button:@"Logs" frame:CGRectMake(margin,1018,inner,46)
                           tint:[UIColor colorWithRed:.42 green:.46 blue:.52 alpha:1]];
    [logs addTarget:self action:@selector(showAuditLogs) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:logs];

    _statusLabel=[self label:@"DEFAULT" frame:CGRectMake(margin,1074,inner,20) size:11 bold:NO];
    _statusLabel.textAlignment=NSTextAlignmentCenter;
    _statusLabel.textColor=[UIColor colorWithWhite:1 alpha:.45];
    [content addSubview:_statusLabel];

    [self registerCustomization];
    [self applyCustomizedLayout];
    [self refreshStatus];
}


#pragma mark - Audit Helpers

- (void)auditErrorResult:(AZError *)error
                 feature:(NSString *)feature
                 details:(NSString *)details {

    BOOL success =
        (error != nil && [error isSuccess]);

    NSString *status =
        success ? @"SUCCESS" : @"ERROR";

    NSString *message =
        details ?: @"";

    if (!success && error != nil) {

        NSString *human =
            error.humanReadableMessage ?: @"";

        NSString *technical =
            error.technicalMessage ?: @"";

        message =
            [NSString stringWithFormat:
                @"code=%ld | human=%@ | technical=%@%@%@",
                (long)error.errorCode,
                human,
                technical,
                message.length ? @" | " : @"",
                message];
    }

    AZAuditLogFeature(
        feature ?: @"unknown",
        status,
        message
    );

    AZAuditLogState(
        feature ?: @"unknown",
        [[AZRuntimeState sharedState] snapshotForUI]
    );
}


- (void)auditStateForFeature:(NSString *)feature
                      status:(NSString *)status
                     details:(NSString *)details {

    AZAuditLogFeature(
        feature ?: @"unknown",
        status ?: @"UNKNOWN",
        details ?: @""
    );

    AZAuditLogState(
        feature ?: @"unknown",
        [[AZRuntimeState sharedState] snapshotForUI]
    );
}

#pragma mark - Map

- (void)mapLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p=[g locationInView:_mapView];
    CLLocationCoordinate2D c =
        [_mapView convertPoint:p
          toCoordinateFromView:_mapView];

    AZAuditLogFeature(
        @"mapLongPress",
        @"SUCCESS",
        [NSString stringWithFormat:
            @"lat=%.8f | lon=%.8f",
            c.latitude,
            c.longitude]
    );

    [self selectCoordinate:c animated:YES];

    // If static location is already enabled, immediately apply the newly
    // selected coordinate so the runtime and CLLocation hooks stay in sync.
    if (_locationSwitch.isOn) {

        AZAuditLogFeature(
            @"mapLongPressLiveUpdate",
            @"REQUESTED",
            [NSString stringWithFormat:
                @"lat=%.8f | lon=%.8f",
                c.latitude,
                c.longitude]
        );

        AZError *e =
            [[AZAppManager sharedManager]
                activateStaticLocationWithLatitude:c.latitude
                longitude:c.longitude];

        [self auditErrorResult:
            e
            feature:@"mapLongPressLiveUpdate"
            details:[NSString stringWithFormat:
                @"lat=%.8f | lon=%.8f",
                c.latitude,
                c.longitude]];
    }
}

- (void)selectCoordinate:(CLLocationCoordinate2D)c animated:(BOOL)animated {
    _selectedCoordinate=c;
    _hasCoordinate=YES;

    NSMutableArray *remove=[NSMutableArray array];
    for (id<MKAnnotation> a in _mapView.annotations) {
        if (![a isKindOfClass:MKUserLocation.class]) [remove addObject:a];
    }
    [_mapView removeAnnotations:remove];

    MKPointAnnotation *pin=[[MKPointAnnotation alloc] init];
    pin.coordinate=c;
    pin.title=@"Selected Location";
    [_mapView addAnnotation:pin];

    MKCoordinateRegion r=MKCoordinateRegionMakeWithDistance(c,650000,650000);
    [_mapView setRegion:r animated:animated];
    [self refreshCoordinate];
}

- (void)refreshCoordinate {
    if (!_coordLabel || !_hasCoordinate) return;
    _coordLabel.text=[NSString stringWithFormat:@"%.6f   %.6f",
                      _selectedCoordinate.latitude,_selectedCoordinate.longitude];
}

- (void)mapModeChanged:(UISegmentedControl *)s {

    _mapView.mapType =
        s.selectedSegmentIndex == 0
            ? MKMapTypeStandard
            : MKMapTypeSatellite;

    AZAuditLogFeature(
        @"mapModeChanged",
        @"SUCCESS",
        [NSString stringWithFormat:
            @"selectedIndex=%ld | mapType=%@",
            (long)s.selectedSegmentIndex,
            s.selectedSegmentIndex == 0
                ? @"STANDARD"
                : @"SATELLITE"]
    );
}

- (void)centerSelected {

    if (!_hasCoordinate) {

        AZAuditLogFeature(
            @"centerSelected",
            @"ERROR",
            @"No selected coordinate"
        );

        return;
    }

    MKCoordinateRegion r =
        MKCoordinateRegionMakeWithDistance(
            _selectedCoordinate,
            1500,
            1500
        );

    [_mapView setRegion:r animated:YES];

    AZAuditLogFeature(
        @"centerSelected",
        @"SUCCESS",
        [NSString stringWithFormat:
            @"lat=%.8f | lon=%.8f",
            _selectedCoordinate.latitude,
            _selectedCoordinate.longitude]
    );
}

- (void)goMyLocation {
    AZAuditLogFeature(@"goMyLocation",@"REQUESTED",@"Requesting fresh real device location");
    __weak AZUIController *weakSelf=self;
    AZRequestRealLocation(^(CLLocation *location,NSError *error) {
        AZUIController *selfRef=weakSelf;
        if (!selfRef) return;
        if (!location) {
            AZAuditLogFeature(@"goMyLocation",@"ERROR",error.localizedDescription);
            [selfRef alert:error.localizedDescription ?: @"تعذر الحصول على الموقع الحقيقي."];
            return;
        }
        AZAuditLogLocation(@"goMyLocation.real",location);
        [selfRef selectCoordinate:location.coordinate animated:YES];
        [selfRef centerSelected];
    });
}

#pragma mark - Search

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {

    NSString *q = searchBar.text;

    if (!q.length) {

        AZAuditLogFeature(
            @"searchLocation",
            @"ERROR",
            @"Empty search query"
        );

        return;
    }

    AZAuditLogFeature(
        @"searchLocation",
        @"REQUESTED",
        [NSString stringWithFormat:
            @"query=%@",
            q]
    );
    [searchBar resignFirstResponder];

    MKLocalSearchRequest *req=[[MKLocalSearchRequest alloc] init];
    req.naturalLanguageQuery=q;
    MKLocalSearch *search=[[MKLocalSearch alloc] initWithRequest:req];

    __weak AZUIController *weakSelf=self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        AZUIController *selfRef=weakSelf;
        if (!selfRef) return;
        if (error || !response.mapItems.count) {
            [selfRef alert:@"\u0644\u0645 \u064A\u062A\u0645 \u0627\u0644\u0639\u062B\u0648\u0631 \u0639\u0644\u0649 \u0627\u0644\u0645\u0648\u0642\u0639."];
            return;
        }
        MKMapItem *item=response.mapItems.firstObject;
        dispatch_async(dispatch_get_main_queue(), ^{
            [selfRef selectCoordinate:item.placemark.coordinate animated:YES];
            if (selfRef->_locationSwitch.isOn) { [[AZAppManager sharedManager] activateStaticLocationWithLatitude:item.placemark.coordinate.latitude longitude:item.placemark.coordinate.longitude]; }
        });
    }];
}

#pragma mark - Core actions

- (void)locationSwitchChanged:(UISwitch *)s {

    AZAuditLogFeature(
        @"locationSwitchChanged",
        @"REQUESTED",
        s.isOn ? @"requested=ON" : @"requested=OFF"
    );

    if (s.isOn) {

        if (!_hasCoordinate) {

            s.on = NO;

            [self auditStateForFeature:
                @"locationSwitchChanged"
                status:@"ERROR"
                details:@"No selected coordinate"];

            [self alert:@"\u062d\u062f\u062f \u0645\u0648\u0642\u0639\u0627\u064b \u0623\u0648\u0644\u0627\u064b."];

            return;
        }

        AZError *e =
            [[AZAppManager sharedManager]
                activateStaticLocationWithLatitude:
                    _selectedCoordinate.latitude
                longitude:
                    _selectedCoordinate.longitude];

        [self auditErrorResult:
            e
            feature:@"activateStaticLocation"
            details:[NSString stringWithFormat:
                @"requestedLat=%.8f | requestedLon=%.8f",
                _selectedCoordinate.latitude,
                _selectedCoordinate.longitude]];

        if (![e isSuccess]) {

            s.on = NO;

            [self alert:
                e.humanReadableMessage
                    ?: @"\u062a\u0639\u0630\u0631 \u062a\u0641\u0639\u064a\u0644 \u0627\u0644\u0645\u0648\u0642\u0639."];
        }
    }
    else {

        AZError *e =
            [[AZAppManager sharedManager]
                restoreDefaultLocation];

        [self auditErrorResult:
            e
            feature:@"restoreDefaultLocation"
            details:@"source=locationSwitchChanged"];
    }

    [self refreshStatus];
}


- (void)restoreLocation {
    AZError *result=[[AZAppManager sharedManager] restoreDefaultLocation];
    [self refreshStatus];
    if (![result isSuccess]) { [self alert:result.humanReadableMessage]; return; }
    // Simulation is disabled before requesting the device position.
    [self goMyLocation];
}

- (void)saveCurrent {

    AZAuditLogFeature(
        @"saveCurrent",
        @"REQUESTED",
        @"Save button pressed"
    );

    if (!_hasCoordinate) {

        [self auditStateForFeature:
            @"saveCurrent"
            status:@"ERROR"
            details:@"No selected coordinate"];

        [self alert:@"\u062d\u062f\u062f \u0645\u0648\u0642\u0639\u0627\u064b \u0623\u0648\u0644\u0627\u064b."];

        return;
    }

    AZError *e =
        [[AZLocationService sharedService]
            addFavoriteWithName:@"AZGPS Location"
            latitude:_selectedCoordinate.latitude
            longitude:_selectedCoordinate.longitude];

    AZAuditLogFeature(
        @"saveCurrent",
        [e isSuccess] ? @"SUCCESS" : @"ERROR",
        [NSString stringWithFormat:
            @"lat=%.8f | lon=%.8f | code=%ld | message=%@",
            _selectedCoordinate.latitude,
            _selectedCoordinate.longitude,
            (long)e.errorCode,
            e.humanReadableMessage ?: @""]
    );

    AZAuditLogState(
        @"saveCurrent",
        [[AZRuntimeState sharedState] snapshotForUI]
    );

    [self alert:
        [e isSuccess]
            ? @"\u062a\u0645 \u062d\u0641\u0638 \u0627\u0644\u0645\u0648\u0642\u0639 \u2705"
            : (e.humanReadableMessage
                ?: @"\u062a\u0639\u0630\u0631 \u0627\u0644\u062d\u0641\u0638.")];
}


- (void)showSaved {
    NSArray<AZLocationModel *> *items=[[AZLocationService sharedService] favorites];
    if (!items.count) { [self alert:@"لا توجد مواقع محفوظة. حدد موقعًا واضغط حفظ أولًا."]; return; }
    UIAlertController *list=[UIAlertController alertControllerWithTitle:@"المواقع المحفوظة"
        message:@"اختر موقعًا للانتقال إليه وتفعيله"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak AZUIController *weakSelf=self;
    for (AZLocationModel *item in items) {
        NSString *title=[NSString stringWithFormat:@"%@ — %.6f, %.6f",item.name,item.latitude,item.longitude];
        [list addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            AZUIController *selfRef=weakSelf;
            if (!selfRef) return;
            AZError *result=[[AZAppManager sharedManager] activateStaticLocationWithLatitude:item.latitude longitude:item.longitude];
            [selfRef auditErrorResult:result feature:@"activateSavedLocation" details:item.locationID];
            if (![result isSuccess]) { [selfRef alert:result.humanReadableMessage]; return; }
            [selfRef selectCoordinate:CLLocationCoordinate2DMake(item.latitude,item.longitude) animated:YES];
            [selfRef centerSelected];
            [selfRef refreshStatus];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter=_overlayWindow.rootViewController;
    while (presenter.presentedViewController) presenter=presenter.presentedViewController;
    // Action sheets need an anchor on iPad.
    list.popoverPresentationController.sourceView=_panel ?: presenter.view;
    list.popoverPresentationController.sourceRect=CGRectMake(14,124,80,48);
    [presenter presentViewController:list animated:YES completion:nil];
}


- (UIViewController *)presenter {
    UIViewController *vc=_overlayWindow.rootViewController;
    while(vc.presentedViewController)vc=vc.presentedViewController;
    return vc;
}
- (void)showMovementControls {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"الحركة الحالية" message:@"أوقف الحركة أو استأنفها، أو ابدأ وضعًا جديدًا." preferredStyle:UIAlertControllerStyleAlert];
    AZAppManager *manager=AZAppManager.sharedManager;
    [alert addAction:[UIAlertAction actionWithTitle:@"إيقاف مؤقت" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[manager pauseMovement];[self refreshStatus];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"استئناف" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[manager resumeMovement];[self refreshStatus];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إيقاف الحركة" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){[manager stopMovement];[self refreshStatus];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"مسار جديد" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[self configureRoute];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"عشوائي جديد" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[self configureRandom];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)routeTapped {
    if(AZRuntimeState.sharedState.movementActive){[self showMovementControls];return;}
    [self configureRoute];
}
- (void)configureRoute {
    if(!_hasCoordinate){[self alert:@"حدد الوجهة على الخريطة أو من المحفوظات أولًا."];return;}
    CLLocationCoordinate2D destination=_selectedCoordinate;
    AZRuntimeState *state=AZRuntimeState.sharedState;
    CLLocationCoordinate2D current=CLLocationCoordinate2DMake(state.currentLatitude,state.currentLongitude);
    BOOL distinct=state.locationEnabled && fabs(current.latitude-destination.latitude)+fabs(current.longitude-destination.longitude)>0.00001;
    if(distinct){[self routeFrom:current to:destination];return;}
    AZRequestRealLocation(^(CLLocation *location,NSError *error){
        if(!location){[self alert:error.localizedDescription];return;}
        [self routeFrom:location.coordinate to:destination];
    });
}
- (void)routeFrom:(CLLocationCoordinate2D)source to:(CLLocationCoordinate2D)destination {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"إعداد المسار"
        message:[NSString stringWithFormat:@"البداية: %.5f, %.5f\nالوجهة: %.5f, %.5f\nالسرعة كم/س",source.latitude,source.longitude,destination.latitude,destination.longitude]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=@"5";field.keyboardType=UIKeyboardTypeDecimalPad;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"عرض المسار" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
        double speed=[alert.textFields.firstObject.text doubleValue]/3.6;
        if(!isfinite(speed)||speed<=0||speed>80){[self alert:@"أدخل سرعة بين 0 و288 كم/س."];return;}
        NSDictionary *from=@{@"lat":@(source.latitude),@"lon":@(source.longitude)},*to=@{@"lat":@(destination.latitude),@"lon":@(destination.longitude)};
        [AZAppManager.sharedManager prepareRouteFrom:from to:to completion:^(NSArray *points,NSError *error){[self previewRoute:points speed:speed fallback:error!=nil];}];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)drawRoute:(NSArray *)points {
    if(!_mapView)return;
    [_mapView removeOverlays:_mapView.overlays];
    NSUInteger count=points.count;if(count<2)return;
    CLLocationCoordinate2D *coordinates=(CLLocationCoordinate2D *)calloc(count,sizeof(CLLocationCoordinate2D));
    for(NSUInteger i=0;i<count;i++)coordinates[i]=CLLocationCoordinate2DMake([points[i][@"lat"]doubleValue],[points[i][@"lon"]doubleValue]);
    MKPolyline *line=[MKPolyline polylineWithCoordinates:coordinates count:count];free(coordinates);
    [_mapView addOverlay:line];
    [_mapView setVisibleMapRect:line.boundingMapRect edgePadding:UIEdgeInsetsMake(25,25,25,25) animated:YES];
}
- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    MKPolylineRenderer *renderer=[[MKPolylineRenderer alloc]initWithOverlay:overlay];renderer.strokeColor=UIColor.blueColor;renderer.lineWidth=4;return renderer;
}
- (void)previewRoute:(NSArray *)points speed:(double)speed fallback:(BOOL)fallback {
    [self drawRoute:points];double distance=0;
    for(NSUInteger i=1;i<points.count;i++){
        CLLocation *a=[[CLLocation alloc]initWithLatitude:[points[i-1][@"lat"]doubleValue] longitude:[points[i-1][@"lon"]doubleValue]];
        CLLocation *b=[[CLLocation alloc]initWithLatitude:[points[i][@"lat"]doubleValue] longitude:[points[i][@"lon"]doubleValue]];
        distance+=[a distanceFromLocation:b];
    }
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:fallback?@"لم يتوفر مسار من الخرائط":@"معاينة المسار"
        message:[NSString stringWithFormat:@"%@\nالمسافة: %.0f متر\nالمدة: %.1f دقيقة",fallback?@"يمكنك اختيار الحركة المباشرة بين النقطتين.":@"المسار جاهز.",distance,distance/speed/60]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:fallback?@"بدء حركة مباشرة":@"بدء المسار" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
        AZError *result=[AZAppManager.sharedManager startRouteWithWaypoints:points speed:speed];
        if(!result.isSuccess)[self alert:result.humanReadableMessage];[self refreshStatus];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action){[AZAppManager.sharedManager stopMovement];[_mapView removeOverlays:_mapView.overlays];}]];
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)randomTapped {
    if(AZRuntimeState.sharedState.movementActive){[self showMovementControls];return;}[self configureRandom];
}
- (void)configureRandom {
    if(!AZRuntimeState.sharedState.locationEnabled){
        AZRequestRealLocation(^(CLLocation *location,NSError *error){
            if(!location){[self alert:error.localizedDescription];return;}
            [AZAppManager.sharedManager activateStaticLocationWithLatitude:location.coordinate.latitude longitude:location.coordinate.longitude];
            [self configureRandom];
        });return;
    }
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"الحركة العشوائية" message:@"حول موقع AZ.GPS الحالي. نصف القطر بالمتر، السرعة كم/س، التحديث بالثواني." preferredStyle:UIAlertControllerStyleAlert];
    for(NSString *value in @[@"100",@"5",@"1"])[alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=value;field.keyboardType=UIKeyboardTypeDecimalPad;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"بدء" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
        AZError *result=[AZAppManager.sharedManager startRandomWithRadius:[alert.textFields[0].text doubleValue] speed:[alert.textFields[1].text doubleValue]/3.6 interval:[alert.textFields[2].text doubleValue]];
        if(!result.isSuccess)[self alert:@"نصف القطر 1–10000 متر، السرعة حتى 288 كم/س، والتحديث 0.25–2 ثانية."];[self refreshStatus];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)scheduleTapped {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"الجدولة" message:@"تعمل أثناء فتح التطبيق فقط. إذا فات الموعد والتطبيق مغلق لا ينفذ بأثر رجعي. الأوقات حسب ساعة الجهاز." preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSString *type in @[@"location",@"route",@"random"]){
        NSString *title=[type isEqual:@"location"]?@"جدولة الموقع الحالي":[type isEqual:@"route"]?@"جدولة آخر مسار":@"جدولة آخر إعداد عشوائي";
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[self configureSchedule:type];}]];
    }
    for(NSDictionary *entry in [AZAppManager.sharedManager schedules]){
        NSInteger minute=[entry[@"minute"]integerValue];
        NSString *title=[NSString stringWithFormat:@"حذف %@ — %02ld:%02ld",entry[@"plan"][@"type"],(long)(minute/60),(long)(minute%60)];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){[AZAppManager.sharedManager deleteSchedule:entry[@"id"]];}]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"تشغيل الجداول" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[AZAppManager.sharedManager startScheduler];[self refreshStatus];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView=_panel ?: [self presenter].view;
    alert.popoverPresentationController.sourceRect=CGRectMake(14,563,80,50);
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)configureSchedule:(NSString *)type {
    if(![type isEqual:@"location"] && ![NSUserDefaults.standardUserDefaults dictionaryForKey:[type isEqual:@"route"]?@"AZ.GPS.lastRoute":@"AZ.GPS.lastRandom"]){[self alert:@"شغل هذا الوضع مرة واحدة أولًا لحفظ إعداداته."];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"موعد التشغيل" message:@"الوقت HH:mm\nالأيام: 1 الأحد … 7 السبت. مثال 1,2,3,4,5,6,7\nإذا تداخلت الجداول ينفذ آخر جدول في القائمة." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"14:30";}];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=@"1,2,3,4,5,6,7";}];
    [alert addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
        NSString *time=alert.textFields[0].text;NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"^([01][0-9]|2[0-3]):[0-5][0-9]$" options:0 error:nil];
        if(![regex numberOfMatchesInString:time options:0 range:NSMakeRange(0,time.length)]){[self alert:@"أدخل الوقت بصيغة HH:mm."];return;}
        NSMutableArray *days=[NSMutableArray new];
        for(NSString *s in [alert.textFields[1].text componentsSeparatedByString:@","]){NSScanner *scanner=[NSScanner scannerWithString:s];NSInteger day=0;if(![scanner scanInteger:&day]||!scanner.isAtEnd||day<1||day>7){[self alert:@"الأيام أرقام من 1 إلى 7 مفصولة بفواصل."];return;}if(![days containsObject:@(day)])[days addObject:@(day)];}
        NSArray *parts=[time componentsSeparatedByString:@":"];
        [AZAppManager.sharedManager addDailyScheduleAt:[parts[0]integerValue]*60+[parts[1]integerValue] weekdays:days type:type];[self refreshStatus];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}

- (void)wifiTapped {

    [self auditStateForFeature:
        @"wifiTapped"
        status:@"UI_ONLY"
        details:@"Wi-Fi profile picker is not connected in this UI version"];

    [self alert:
        @"\u0648\u0627\u062c\u0647\u0629 Wi-Fi \u062c\u0627\u0647\u0632\u0629. \u064a\u0644\u0632\u0645 \u0627\u062e\u062a\u064a\u0627\u0631 Profile ID \u0644\u0631\u0628\u0637\u0647\u0627 \u0628\u0627\u0644\u0640 Core."];
}


- (void)bluetoothTapped {

    [self auditStateForFeature:
        @"bluetoothTapped"
        status:@"UI_ONLY"
        details:@"Bluetooth feature is not connected in this build"];

    [self alert:
        @"Bluetooth UI \u0641\u0642\u0637 \u0641\u064a \u0647\u0630\u0647 \u0627\u0644\u0646\u0633\u062e\u0629."];
}


- (void)deviceAction:(UIButton *)sender {
    AZAppManager *manager=AZAppManager.sharedManager;
    if(sender.tag==0){
        NSString *value=AZCurrentIdentity();
        if(!value.length){[self alert:@"معرف التطبيق غير متاح حاليًا من iOS."];return;}
        UIPasteboard.generalPasteboard.string=value;
        [self alert:[NSString stringWithFormat:@"تم نسخ المعرف الذي يراه التطبيق الآن:\n%@",value]];
    }else if(sender.tag==1){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"تعبئة معرف الجهاز" message:@"أدخل UUID لتفعيل استبدال identifierForVendor داخل التطبيق. يبقى محفوظًا بعد إعادة تشغيل التطبيق." preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
            field.placeholder=@"XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX";
            field.text=AZSavedIdentity().length?AZSavedIdentity():AZCurrentIdentity();
            field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeAllCharacters;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"حفظ وتفعيل" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
            
            // Empty input is invalid here; restoration has its own button.
            if(![alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length){
                [self alert:@"أدخل UUID صالحًا."];return;
            }
            AZError *result=[manager setActiveDeviceProfileWithID:alert.textFields.firstObject.text];
            if(!result.isSuccess){[self alert:@"UUID غير صالح. مثال: 550E8400-E29B-41D4-A716-446655440000"];return;}
            [self alert:[NSString stringWithFormat:@"المعرف المفعّل:\n%@",AZCurrentIdentity()]];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
        [[self presenter]presentViewController:alert animated:YES completion:nil];
    }else if(sender.tag==2){
        NSString *value=NSUUID.UUID.UUIDString;
        AZError *result=[manager setActiveDeviceProfileWithID:value];
        if(!result.isSuccess){[self alert:result.humanReadableMessage];return;}
        [self alert:[NSString stringWithFormat:@"تم توليد وحفظ وتفعيل هوية جديدة:\n%@",AZCurrentIdentity()]];
    }else if(sender.tag==3){
        [manager setActiveDeviceProfileWithID:@""];
        NSString *value=AZCurrentIdentity();
        [self alert:value.length?[NSString stringWithFormat:@"تمت استعادة المعرف الأصلي:\n%@",value]:@"تم تعطيل الاستبدال. المعرف الأصلي غير متاح حاليًا من iOS."];
    }
}

- (void)stopAll {

    AZAuditLogFeature(
        @"stopAll",
        @"REQUESTED",
        @"Stopping movement and restoring default location"
    );

    AZError *stopError =
        [[AZAppManager sharedManager]
            stopMovement];

    [self auditErrorResult:
        stopError
        feature:@"stopMovement"
        details:@"source=Stop All"];

    AZError *restoreError =
        [[AZAppManager sharedManager]
            restoreDefaultLocation];

    [self auditErrorResult:
        restoreError
        feature:@"restoreDefaultLocation"
        details:@"source=Stop All"];

    _locationSwitch.on = NO;

    [self refreshStatus];

    [self alert:
        @"\u062a\u0645 \u0625\u064a\u0642\u0627\u0641 \u062d\u0627\u0644\u0629 AZGPS Runtime \u0627\u0644\u062d\u0627\u0644\u064a\u0629."];
}


- (void)refreshStatus {
    NSDictionary *s=[[AZRuntimeState sharedState] snapshotForUI];
    BOOL active=[s[@"locationEnabled"] boolValue];
    if (_statusLabel) _statusLabel.text=[s[@"movementActive"]boolValue] ? [NSString stringWithFormat:@"%@ %@ • %.0f%%", [s[@"randomMovementActive"]boolValue]?@"عشوائي":@"مسار", [s[@"movementPaused"]boolValue]?@"متوقف مؤقتًا":@"يعمل", [s[@"routeProgress"]doubleValue]*100] : (active ? @"LOCATION ACTIVE" : @"DEFAULT");
    if (_locationSwitch) _locationSwitch.on=active;
    if (_mapView && [s[@"movementActive"]boolValue]) {
        if (!_movementPin) {_movementPin=[MKPointAnnotation new];_movementPin.title=@"AZ.GPS — الموقع المتحرك";[_mapView addAnnotation:_movementPin];}
        _movementPin.coordinate=CLLocationCoordinate2DMake([s[@"currentLatitude"]doubleValue],[s[@"currentLongitude"]doubleValue]);
    } else if (_movementPin) {[_mapView removeAnnotation:_movementPin];_movementPin=nil;}

}


#pragma mark - Audit Logs

- (void)showAuditLogs {
    AZAuditLogNSString(
        @"UI",
        @"Logs viewer requested"
    );

    UIViewController *vc = _overlayWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }

    AZAuditPresentLogs(vc);
}

#pragma mark - Informational

- (void)showStatus {
    NSDictionary *s=[[AZRuntimeState sharedState] snapshotForUI];
    NSString *m=[NSString stringWithFormat:
                 @"Location: %@\nLat: %.6f\nLon: %.6f\nLast: %@",
                 [s[@"locationEnabled"] boolValue] ? @"Active" : @"Default",
                 [s[@"currentLatitude"] doubleValue],
                 [s[@"currentLongitude"] doubleValue],
                 s[@"lastAction"] ?: @""];
    [self alert:m];
}

- (void)showSupport {
    [self alert:@"AZ.GPS"];
}

- (void)notImplemented {
    [self alert:@"\u0647\u0630\u0647 \u0627\u0644\u0648\u0627\u062C\u0647\u0629 \u0645\u0648\u062C\u0648\u062F\u0629\u060C \u0644\u0643\u0646 \u0627\u0644\u0648\u0638\u064A\u0641\u0629 \u063A\u064A\u0631 \u0645\u0648\u0635\u0648\u0644\u0629 \u0628\u0627\u0644\u0640 Core \u0627\u0644\u062D\u0627\u0644\u064A \u0628\u0639\u062F."];
}

- (void)alert:(NSString *)message {
    UIViewController *vc=_overlayWindow.rootViewController;
    while (vc.presentedViewController) vc=vc.presentedViewController;

    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"AZ.GPS"
                                                             message:message ?: @""
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                         style:UIAlertActionStyleDefault
                                       handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}


#pragma mark - Customization
- (NSDictionary *)appearancePreferences {return [NSUserDefaults.standardUserDefaults dictionaryForKey:AZAppearancePrefsKey] ?: @{};}
- (NSDictionary *)layoutPreferences {return [NSUserDefaults.standardUserDefaults dictionaryForKey:AZLayoutPrefsKey] ?: @{};}
- (UIColor *)customAccent {
    NSString *hex=[self appearancePreferences][@"accent"];if(!hex.length)return nil;
    unsigned value=0;[[NSScanner scannerWithString:hex]scanHexInt:&value];
    return [UIColor colorWithRed:((value>>16)&255)/255.0 green:((value>>8)&255)/255.0 blue:(value&255)/255.0 alpha:1];
}
- (void)applyFloatingPreferences {
    NSDictionary *prefs=[self appearancePreferences];CGFloat size=prefs[@"size"]?[prefs[@"size"]doubleValue]:62;
    size=MAX(44,MIN(110,size));CGFloat alpha=prefs[@"alpha"]?[prefs[@"alpha"]doubleValue]:1;
    UIView *root=_floatingButton.superview;CGFloat w=CGRectGetWidth(root.bounds),h=CGRectGetHeight(root.bounds);
    CGPoint center=_floatingButton.center;
    if(prefs[@"x"]&&prefs[@"y"])center=CGPointMake([prefs[@"x"]doubleValue]*w,[prefs[@"y"]doubleValue]*h);
    center.x=MAX(size/2,MIN(w-size/2,center.x));center.y=MAX(size/2,MIN(h-size/2,center.y));
    _floatingButton.bounds=CGRectMake(0,0,size,size);_floatingButton.center=center;
    _floatingButton.layer.cornerRadius=size/2;_floatingButton.alpha=MAX(0.25,MIN(1,alpha));
    _floatingButton.titleLabel.font=[UIFont systemFontOfSize:size*0.47];
    _floatingButton.backgroundColor=[self customAccent] ?: [UIColor colorWithRed:0.08 green:0.09 blue:0.1 alpha:0.98];
}
- (void)customizationLongPress:(UILongPressGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateBegan)return;
    if(!_panel)[self buildPanel];[self showCustomization];
}
- (BOOL)isCustomizationButton:(UIButton *)button {
    return [[button actionsForTarget:self forControlEvent:UIControlEventTouchUpInside]containsObject:@"showCustomization"];
}
- (void)registerViews:(UIView *)container path:(NSString *)path {
    NSUInteger index=0;
    for(UIView *view in container.subviews){
        NSString *key=[NSString stringWithFormat:@"%@/%lu",path,(unsigned long)index++];
        objc_setAssociatedObject(view,&AZBaseFrameKey,[NSValue valueWithCGRect:view.frame],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if([view isKindOfClass:UIButton.class]){
            UIButton *button=(UIButton *)view;
            objc_setAssociatedObject(button,&AZButtonKey,key,OBJC_ASSOCIATION_COPY_NONATOMIC);
            NSString *title=[button titleForState:UIControlStateNormal] ?: @"زر";
            [_customButtons addObject:@{@"key":key,@"title":title,@"button":button}];
        }else if([view class]==UIView.class){[self registerViews:view path:key];}
    }
}
- (void)registerCustomization {
    _customButtons=[NSMutableArray new];[self registerViews:_content path:@"panel"];
}
- (CGRect)baseFrame:(UIView *)view {
    NSValue *value=objc_getAssociatedObject(view,&AZBaseFrameKey);return value?value.CGRectValue:view.frame;
}
- (CGFloat)reflowContainer:(UIView *)container {
    NSArray *ordered=[container.subviews sortedArrayUsingComparator:^NSComparisonResult(UIView *a,UIView *b){
        CGRect x=[self baseFrame:a],y=[self baseFrame:b];if(x.origin.y<y.origin.y)return NSOrderedAscending;if(x.origin.y>y.origin.y)return NSOrderedDescending;
        return x.origin.x<y.origin.x?NSOrderedAscending:NSOrderedDescending;
    }];
    NSMutableArray *groups=[NSMutableArray new];NSMutableArray *group=nil;CGFloat end=-1;
    for(UIView *view in ordered){
        CGRect base=[self baseFrame:view];
        if(!group||base.origin.y>=end){group=[NSMutableArray new];[groups addObject:group];end=CGRectGetMaxY(base);}
        [group addObject:view];end=MAX(end,CGRectGetMaxY(base));
    }
    NSDictionary *prefs=[self layoutPreferences];CGFloat shift=0;
    for(NSArray *row in groups){
        CGFloat start=CGFLOAT_MAX,oldEnd=0,newEnd=0;NSMutableArray *buttons=[NSMutableArray new];BOOL changed=NO;
        for(UIView *view in row){
            CGRect base=[self baseFrame:view];start=MIN(start,base.origin.y);oldEnd=MAX(oldEnd,CGRectGetMaxY(base));
            if([view isKindOfClass:UIButton.class]){
                [buttons addObject:view];NSString *key=objc_getAssociatedObject(view,&AZButtonKey);NSDictionary *setting=prefs[key];
                if(setting.count)changed=YES;
            }else if([view class]==UIView.class){
                CGFloat height=[self reflowContainer:view];CGRect frame=base;frame.size.height=height;view.frame=frame;
            }else view.frame=base;
        }
        CGFloat nonButtonEnd=start;
        for(UIView *view in row)if(![view isKindOfClass:UIButton.class]){
            CGRect frame=view.frame;frame.origin.y=[self baseFrame:view].origin.y+shift;view.frame=frame;
            newEnd=MAX(newEnd,CGRectGetMaxY(frame));nonButtonEnd=MAX(nonButtonEnd,CGRectGetMaxY(frame)-shift);
        }
        NSArray *sorted=[buttons sortedArrayUsingComparator:^NSComparisonResult(UIView *a,UIView *b){return [self baseFrame:a].origin.x<[self baseFrame:b].origin.x?NSOrderedAscending:NSOrderedDescending;}];
        CGFloat left=sorted.count?[self baseFrame:sorted.firstObject].origin.x:0;
        CGFloat x=left,y=row.count==buttons.count?start:nonButtonEnd+8,lineHeight=0;
        CGFloat width=CGRectGetWidth(container.bounds);
        for(UIButton *button in sorted){
            CGRect base=[self baseFrame:button];NSDictionary *setting=prefs[objc_getAssociatedObject(button,&AZButtonKey)];
            BOOL protected=[self isCustomizationButton:button];button.hidden=!protected&&[setting[@"hidden"]boolValue];
            if(button.hidden)continue;
            CGRect frame=base;
            if(changed){
                frame.size.width=setting[@"width"]?MAX(44,MIN(width-left*2,[setting[@"width"]doubleValue])):MIN(base.size.width,width-left*2);
                frame.size.height=setting[@"height"]?MAX(32,MIN(160,[setting[@"height"]doubleValue])):base.size.height;
                if(x>left&&x+frame.size.width>width-left){x=left;y+=lineHeight+8;lineHeight=0;}
                frame.origin=CGPointMake(x,y+shift);x+=frame.size.width+8;lineHeight=MAX(lineHeight,frame.size.height);
            }else frame.origin.y+=shift;
            button.frame=frame;newEnd=MAX(newEnd,CGRectGetMaxY(frame));
        }
        if(!newEnd)newEnd=start+shift;shift+=newEnd-(oldEnd+shift);
    }
    return MAX(1,CGRectGetHeight([self baseFrame:container])+shift);
}
- (void)applyCustomizedLayout {
    UIColor *accent=[self customAccent];
    for(NSDictionary *item in _customButtons){
        UIButton *button=item[@"button"];
        if(accent){button.backgroundColor=[accent colorWithAlphaComponent:0.23];button.layer.borderColor=[accent colorWithAlphaComponent:0.65].CGColor;}
    }
    if([self layoutPreferences].count){
        CGFloat height=[self reflowContainer:_content];CGRect frame=_content.frame;frame.size.height=height;_content.frame=frame;_panel.contentSize=frame.size;
    }
}
- (void)rebuildCustomizedPanel {
    BOOL open=_panel!=nil;if(open){[self closePanel];[self buildPanel];}[self applyFloatingPreferences];
}
- (void)showCustomization {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"تخصيص AZ.GPS" message:@"تغيير حجم الأزرار وإخفاؤها لا يوقف الوظائف التي تعمل. زر التخصيص يبقى متاحًا." preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"تعديل الأزرار وإظهار المخفي" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self showButtonEditorList];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"اللون والزر العائم" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self showAppearanceEditor];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إرجاع الافتراضي" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){[self confirmResetCustomization];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView=_panel ?: _floatingButton;
    alert.popoverPresentationController.sourceRect=alert.popoverPresentationController.sourceView.bounds;
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)showButtonEditorList {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"أزرار الواجهة" message:@"اختر زرًا لتعديل عرضه وارتفاعه أو إخفائه." preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *prefs=[self layoutPreferences];
    for(NSDictionary *item in _customButtons){
        BOOL hidden=[prefs[item[@"key"]][@"hidden"]boolValue];
        NSString *title=[NSString stringWithFormat:@"%@%@ %@",hidden?@"مخفي • ":@"",item[@"title"],[item[@"button"] isEnabled]?@"":@"(غير متاح)"];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self editButton:item];}]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView=_panel;alert.popoverPresentationController.sourceRect=_panel.bounds;
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)editButton:(NSDictionary *)item {
    UIButton *button=item[@"button"];CGRect base=[self baseFrame:button];NSDictionary *setting=[self layoutPreferences][item[@"key"]];
    BOOL protected=[self isCustomizationButton:button];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:item[@"title"] message:@"العرض 44–340 والارتفاع 32–160 نقطة. العرض يتكيّف مع مساحة الواجهة. إخفاء الزر قابل للاستعادة." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"العرض";f.text=[NSString stringWithFormat:@"%.0f",setting[@"width"]?[setting[@"width"]doubleValue]:base.size.width];f.keyboardType=UIKeyboardTypeDecimalPad;}];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"الارتفاع";f.text=[NSString stringWithFormat:@"%.0f",setting[@"height"]?[setting[@"height"]doubleValue]:base.size.height];f.keyboardType=UIKeyboardTypeDecimalPad;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"حفظ الحجم" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        double width=[alert.textFields[0].text doubleValue],height=[alert.textFields[1].text doubleValue];
        if(!isfinite(width)||!isfinite(height)||width<44||width>340||height<32||height>160){[self alert:@"أدخل عرضًا 44–340 وارتفاعًا 32–160."];return;}
        NSMutableDictionary *prefs=[[self layoutPreferences]mutableCopy];prefs[item[@"key"]]=@{@"width":@(width),@"height":@(height),@"hidden":@(!protected&&[setting[@"hidden"]boolValue])};
        [NSUserDefaults.standardUserDefaults setObject:prefs forKey:AZLayoutPrefsKey];[self rebuildCustomizedPanel];
    }]];
    if(!protected)[alert addAction:[UIAlertAction actionWithTitle:[setting[@"hidden"]boolValue]?@"إظهار الزر":@"إخفاء الزر" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        NSMutableDictionary *prefs=[[self layoutPreferences]mutableCopy],*value=[setting mutableCopy] ?: [NSMutableDictionary new];value[@"hidden"]=@(![setting[@"hidden"]boolValue]);prefs[item[@"key"]]=value;
        [NSUserDefaults.standardUserDefaults setObject:prefs forKey:AZLayoutPrefsKey];[self rebuildCustomizedPanel];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إعادة هذا الزر للافتراضي" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        NSMutableDictionary *prefs=[[self layoutPreferences]mutableCopy];[prefs removeObjectForKey:item[@"key"]];[NSUserDefaults.standardUserDefaults setObject:prefs forKey:AZLayoutPrefsKey];[self rebuildCustomizedPanel];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)showAppearanceEditor {
    NSDictionary *prefs=[self appearancePreferences];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"المظهر والزر العائم" message:@"لون HEX مثل 0099FF (اتركه فارغًا للون الأصلي). حجم الزر 44–110، الشفافية 25–100%. موضع الزر يُحفظ تلقائيًا عند سحبه." preferredStyle:UIAlertControllerStyleAlert];
    NSArray *values=@[prefs[@"accent"] ?: @"",[NSString stringWithFormat:@"%.0f",prefs[@"size"]?[prefs[@"size"]doubleValue]:62],[NSString stringWithFormat:@"%.0f",prefs[@"alpha"]?[prefs[@"alpha"]doubleValue]*100:100]];
    NSArray *names=@[@"لون HEX",@"حجم الزر",@"الشفافية %"];
    for(NSUInteger i=0;i<3;i++)[alert addTextFieldWithConfigurationHandler:^(UITextField *f){f.text=values[i];f.placeholder=names[i];f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        NSString *hex=[[alert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]uppercaseString];if([hex hasPrefix:@"#"])hex=[hex substringFromIndex:1];
        NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"^[0-9A-F]{6}$" options:0 error:nil];
        double size=[alert.textFields[1].text doubleValue],alpha=[alert.textFields[2].text doubleValue]/100;
        if((hex.length&&![regex numberOfMatchesInString:hex options:0 range:NSMakeRange(0,hex.length)])||!isfinite(size)||size<44||size>110||!isfinite(alpha)||alpha<0.25||alpha>1){[self alert:@"تحقق من اللون والحجم والشفافية."];return;}
        NSMutableDictionary *value=[prefs mutableCopy];value[@"accent"]=hex;value[@"size"]=@(size);value[@"alpha"]=@(alpha);
        [NSUserDefaults.standardUserDefaults setObject:value forKey:AZAppearancePrefsKey];[self rebuildCustomizedPanel];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}
- (void)confirmResetCustomization {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"إرجاع الواجهة الافتراضية؟" message:@"يرجع أحجام الأزرار ويظهرها ويعيد اللون وحجم وشفافية وموضع الزر العائم." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إرجاع الافتراضي" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){
        [NSUserDefaults.standardUserDefaults removeObjectForKey:AZLayoutPrefsKey];[NSUserDefaults.standardUserDefaults removeObjectForKey:AZAppearancePrefsKey];
        _floatingButton.frame=CGRectMake(18,160,62,62);[self rebuildCustomizedPanel];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter]presentViewController:alert animated:YES completion:nil];
}


#pragma mark - Close

- (void)closePanel {
    [_searchBar resignFirstResponder];
    [_panel removeFromSuperview];

    _panel=nil;
    _content=nil;
    _searchBar=nil;
    _mapView=nil;
    _movementPin=nil;
    _coordLabel=nil;
    _statusLabel=nil;
    _locationSwitch=nil;
    _photoSwitch=nil;

    _floatingButton.hidden=NO;
}

@end
