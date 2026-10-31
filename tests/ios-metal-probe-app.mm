#import <UIKit/UIKit.h>
#include <cstdio>
#include <cstdlib>

int angleDeviceInfoMain();
#if !defined(ANGLE_CAPABILITIES_ONLY)
int angleProfileProbeMain(int argc, char **argv);
int angleCullingProbeMain(int argc, char **argv);
#endif

@interface AngleDeviceProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) BOOL started;
- (void)runProbes;
@end

@interface AngleDeviceProbeScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AngleDeviceProbeDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
  return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
  UISceneConfiguration *configuration =
      [[UISceneConfiguration alloc] initWithName:@"ANGLE Device Probe"
                                     sessionRole:session.role];
  configuration.delegateClass = AngleDeviceProbeScene.class;
  return configuration;
}

- (void)runProbes {
  if (self.started) {
    return;
  }
  self.started = YES;
  NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
  NSString *profile = arguments.count > 1 ? arguments[1] : @"capabilities";
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      std::setvbuf(stdout, nullptr, _IONBF, 0);
      NSString *directory = NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
      std::puts("METAL_DEVICE_INFO_BEGIN");
      int deviceStatus = angleDeviceInfoMain();
      std::puts("METAL_DEVICE_INFO_END");
      int profileStatus = -1;
      int cullingStatus = -1;
      BOOL passed = deviceStatus == 0;
      if (![profile isEqualToString:@"capabilities"]) {
#if defined(ANGLE_CAPABILITIES_ONLY)
        passed = NO;
        std::fputs("This app only measures Metal capabilities\n", stderr);
#else
        char executable[] = "metal-profile-probe";
        char *profileArguments[] = {
            executable, const_cast<char *>(profile.UTF8String), nullptr};
        profileStatus = angleProfileProbeMain(2, profileArguments);
        if (profileStatus == 0 && [profile isEqualToString:@"gles31"]) {
          NSString *image = [directory stringByAppendingPathComponent:@"culling.ppm"];
          char cullingExecutable[] = "metal-culling-probe";
          char *cullingArguments[] = {
              cullingExecutable, const_cast<char *>(image.fileSystemRepresentation), nullptr};
          cullingStatus = angleCullingProbeMain(2, cullingArguments);
        }
        passed = passed && profileStatus == 0 &&
                 (![profile isEqualToString:@"gles31"] || cullingStatus == 0);
#endif
      }
      NSDictionary *result = @{
        @"passed" : @(passed), @"profile" : profile,
        @"device_status" : @(deviceStatus), @"profile_status" : @(profileStatus),
        @"culling_status" : @(cullingStatus),
        @"os" : NSProcessInfo.processInfo.operatingSystemVersionString
      };
      NSData *data = [NSJSONSerialization dataWithJSONObject:result
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
      BOOL written = [data writeToFile:[directory stringByAppendingPathComponent:@"result.json"]
                               options:NSDataWritingAtomic error:nil];
      std::printf("IOS_DEVICE_METAL_%s profile=%s\n",
                  passed && written ? "PASS" : "FAIL", profile.UTF8String);
      std::fflush(nullptr);
      std::exit(passed && written ? 0 : 1);
    }
  });
}
@end

@implementation AngleDeviceProbeScene
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  UIViewController *controller = [[UIViewController alloc] init];
  controller.view.backgroundColor = UIColor.systemBackgroundColor;
  UILabel *label = [[UILabel alloc] initWithFrame:self.window.bounds];
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  label.text = @"Running ANGLE Metal verification";
  [controller.view addSubview:label];
  self.window.rootViewController = controller;
  [self.window makeKeyAndVisible];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
  [(AngleDeviceProbeDelegate *)UIApplication.sharedApplication.delegate runProbes];
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil,
                             NSStringFromClass(AngleDeviceProbeDelegate.class));
  }
}
