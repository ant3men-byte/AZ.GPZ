#import "AZGPS.h"
#import "UI.h"
#import "Audit.h"

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>

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
    for (UIButton *pending in @[route,random,schedule]) { pending.enabled=NO; pending.alpha=0.4; }
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
        b.tag=i; b.enabled=NO; b.alpha=0.4;
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
    [custom addTarget:self action:@selector(notImplemented) forControlEvents:UIControlEventTouchUpInside];
    custom.enabled=NO;custom.alpha=0.4;
    [content addSubview:stop]; [content addSubview:hide]; [content addSubview:custom];

    UIButton *logs=[self button:@"Logs" frame:CGRectMake(margin,1018,inner,46)
                           tint:[UIColor colorWithRed:.42 green:.46 blue:.52 alpha:1]];
    [logs addTarget:self action:@selector(showAuditLogs) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:logs];

    _statusLabel=[self label:@"DEFAULT" frame:CGRectMake(margin,1074,inner,20) size:11 bold:NO];
    _statusLabel.textAlignment=NSTextAlignmentCenter;
    _statusLabel.textColor=[UIColor colorWithWhite:1 alpha:.45];
    [content addSubview:_statusLabel];

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

    NSArray *items =
        [[AZLocationService sharedService]
            favorites];

    AZAuditLogFeature(
        @"showSaved",
        @"SUCCESS",
        [NSString stringWithFormat:
            @"favoritesCount=%lu",
            (unsigned long)items.count]
    );

    [self alert:
        [NSString stringWithFormat:
            @"\u0639\u062f\u062f \u0627\u0644\u0645\u0648\u0627\u0642\u0639 \u0627\u0644\u0645\u062d\u0641\u0648\u0638\u0629: %lu",
            (unsigned long)items.count]];
}


- (void)routeTapped {

    AZAuditLogFeature(
        @"routeTapped",
        @"REQUESTED",
        @"Preparing two-point route"
    );

    if (!_hasCoordinate) {

        [self auditStateForFeature:
            @"routeTapped"
            status:@"ERROR"
            details:@"No destination selected"];

        [self alert:
            @"\u062d\u062f\u062f \u0646\u0642\u0637\u0629 \u0627\u0644\u0648\u0635\u0648\u0644 \u0639\u0644\u0649 \u0627\u0644\u062e\u0631\u064a\u0637\u0629 \u0623\u0648\u0644\u0627\u064b."];

        return;
    }

    CLLocationCoordinate2D destination =
        _selectedCoordinate;

    CLLocationCoordinate2D start =
        kCLLocationCoordinate2DInvalid;

    CLLocation *mapLocation =
        _mapView.userLocation.location;

    if (mapLocation != nil &&
        CLLocationCoordinate2DIsValid(mapLocation.coordinate)) {

        start =
            mapLocation.coordinate;
    }
    else {

        AZRuntimeState *state =
            [AZRuntimeState sharedState];

        if (state.locationEnabled &&
            state.currentLatitude >= -90.0 &&
            state.currentLatitude <= 90.0 &&
            state.currentLongitude >= -180.0 &&
            state.currentLongitude <= 180.0) {

            start =
                CLLocationCoordinate2DMake(
                    state.currentLatitude,
                    state.currentLongitude
                );
        }
    }

    if (!CLLocationCoordinate2DIsValid(start)) {

        [self auditStateForFeature:
            @"routeTapped"
            status:@"ERROR"
            details:@"No valid start location available"];

        [self alert:
            @"\u0644\u0645 \u064a\u062a\u0645 \u0627\u0644\u0639\u062b\u0648\u0631 \u0639\u0644\u0649 \u0646\u0642\u0637\u0629 \u0628\u062f\u0627\u064a\u0629. \u0627\u0636\u063a\u0637 \u0645\u0648\u0642\u0639\u064a \u0623\u0648\u0644\u0627\u064b \u062b\u0645 \u062d\u062f\u062f \u0627\u0644\u0648\u062c\u0647\u0629."];

        return;
    }

    CLLocation *startLocation =
        [[CLLocation alloc]
            initWithLatitude:start.latitude
            longitude:start.longitude];

    CLLocation *endLocation =
        [[CLLocation alloc]
            initWithLatitude:destination.latitude
            longitude:destination.longitude];

    CLLocationDistance distance =
        [startLocation distanceFromLocation:endLocation];

    if (distance < 2.0) {

        [self auditStateForFeature:
            @"routeTapped"
            status:@"ERROR"
            details:@"Start and destination are effectively the same"];

        [self alert:
            @"\u0646\u0642\u0637\u0629 \u0627\u0644\u0628\u062f\u0627\u064a\u0629 \u0648\u0627\u0644\u0648\u062c\u0647\u0629 \u0645\u062a\u0637\u0627\u0628\u0642\u062a\u0627\u0646. \u062d\u062f\u062f \u0648\u062c\u0647\u0629 \u0623\u062e\u0631\u0649."];

        return;
    }

    UIAlertController *sheet =
        [UIAlertController
            alertControllerWithTitle:@"Route"
            message:[NSString stringWithFormat:
                @"Distance: %.0f m\nEnter speed in m/s",
                distance]
            preferredStyle:UIAlertControllerStyleAlert];

    [sheet addTextFieldWithConfigurationHandler:
        ^(UITextField *field) {

            field.placeholder = @"Speed";
            field.text = @"5.0";
            field.keyboardType =
                UIKeyboardTypeDecimalPad;
        }];

    __weak AZUIController *weakSelf = self;

    UIAlertAction *startAction =
        [UIAlertAction
            actionWithTitle:@"Start"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {

                (void)action;

                AZUIController *selfRef =
                    weakSelf;

                if (!selfRef) return;

                double speed =
                    [sheet.textFields.firstObject.text
                        doubleValue];

                if (speed <= 0.0 || speed > 300.0) {

                    [selfRef auditStateForFeature:
                        @"routeTapped"
                        status:@"ERROR"
                        details:@"Invalid route speed"];

                    [selfRef alert:
                        @"\u0627\u0644\u0633\u0631\u0639\u0629 \u063a\u064a\u0631 \u0635\u062d\u064a\u062d\u0629."];

                    return;
                }

                NSArray *waypoints =
                    @[
                        @{
                            @"lat": @(start.latitude),
                            @"lon": @(start.longitude)
                        },
                        @{
                            @"lat": @(destination.latitude),
                            @"lon": @(destination.longitude)
                        }
                    ];

                AZError *e =
                    [[AZAppManager sharedManager]
                        startRouteWithWaypoints:waypoints
                        speed:speed];

                [selfRef auditErrorResult:
                    e
                    feature:@"startRoute"
                    details:[NSString stringWithFormat:
                        @"from=%.8f,%.8f | to=%.8f,%.8f | speed=%.2f | distance=%.2f",
                        start.latitude,
                        start.longitude,
                        destination.latitude,
                        destination.longitude,
                        speed,
                        distance]];

                if ([e isSuccess]) {

                    selfRef->_locationSwitch.on =
                        YES;

                    [selfRef alert:
                        @"Route started \u2705"];
                }
                else {

                    [selfRef alert:
                        e.humanReadableMessage
                            ?: @"Route failed."];
                }

                [selfRef refreshStatus];
            }];

    UIAlertAction *cancelAction =
        [UIAlertAction
            actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel
            handler:nil];

    [sheet addAction:startAction];
    [sheet addAction:cancelAction];

    UIViewController *presenter =
        _overlayWindow.rootViewController;

    [presenter
        presentViewController:sheet
        animated:YES
        completion:nil];
}


- (void)randomTapped {

    AZAuditLogFeature(
        @"randomTapped",
        @"REQUESTED",
        @"radius=100.0m"
    );

    AZError *e =
        [[AZAppManager sharedManager]
            startRandomMovementWithRadius:100.0];

    [self auditErrorResult:
        e
        feature:@"startRandomMovement"
        details:@"radius=100.0m"];

    [self alert:
        [e isSuccess]
            ? @"\u062a\u0645 \u062a\u0634\u063a\u064a\u0644 \u0627\u0644\u0648\u0636\u0639 \u0627\u0644\u0639\u0634\u0648\u0627\u0626\u064a \u0641\u064a AZGPS Runtime \u2705"
            : (e.humanReadableMessage
                ?: @"\u062a\u0639\u0630\u0631 \u0627\u0644\u062a\u0634\u063a\u064a\u0644.")];

    [self refreshStatus];
}


- (void)scheduleTapped {

    AZAuditLogFeature(
        @"scheduleTapped",
        @"REQUESTED",
        @"Start scheduler requested"
    );

    AZError *e =
        [[AZAppManager sharedManager]
            startScheduler];

    [self auditErrorResult:
        e
        feature:@"startScheduler"
        details:@"source=Scheduler button"];

    [self alert:
        [e isSuccess]
            ? @"\u062a\u0645 \u062a\u0634\u063a\u064a\u0644 Scheduler \u0641\u064a AZGPS Runtime \u2705"
            : (e.humanReadableMessage
                ?: @"\u062a\u0639\u0630\u0631 \u0627\u0644\u062a\u0634\u063a\u064a\u0644.")];

    [self refreshStatus];
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

    NSString *actionName = @"unknown";

    switch (sender.tag) {
        case 0: actionName = @"copy"; break;
        case 1: actionName = @"fill"; break;
        case 2: actionName = @"identity"; break;
        case 3: actionName = @"restore"; break;
        default: break;
    }

    AZAuditLogFeature(
        @"deviceAction",
        @"REQUESTED",
        [NSString stringWithFormat:
            @"action=%@ | tag=%ld",
            actionName,
            (long)sender.tag]
    );

    if (sender.tag == 3) {

        AZError *e =
            [[AZAppManager sharedManager]
                setActiveDeviceProfileWithID:@""];

        [self auditErrorResult:
            e
            feature:@"restoreDeviceProfile"
            details:@"profileID=<empty>"];
    }
    else {

        [self auditStateForFeature:
            @"deviceAction"
            status:@"UI_ONLY"
            details:[NSString stringWithFormat:
                @"action=%@ is not connected to data layer",
                actionName]];
    }

    [self alert:
        @"Device Profile UI \u062c\u0627\u0647\u0632\u0629 \u0644\u0644\u062a\u0648\u0635\u064a\u0644 \u0628\u0627\u0644\u0628\u064a\u0627\u0646\u0627\u062a \u0627\u0644\u0641\u0639\u0644\u064a\u0629."];
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
    if (_statusLabel) _statusLabel.text=active ? @"LOCATION ACTIVE" : @"DEFAULT";
    if (_locationSwitch) _locationSwitch.on=active;
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

#pragma mark - Close

- (void)closePanel {
    [_searchBar resignFirstResponder];
    [_panel removeFromSuperview];

    _panel=nil;
    _content=nil;
    _searchBar=nil;
    _mapView=nil;
    _coordLabel=nil;
    _statusLabel=nil;
    _locationSwitch=nil;
    _photoSwitch=nil;

    _floatingButton.hidden=NO;
}

@end
