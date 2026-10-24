#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
int main(int c, const char **v) {
  @autoreleasepool {
    if (c < 3) { printf("用法: setdef <App路徑> <UTI>\n"); return 1; }
    NSURL *app = [NSURL fileURLWithPath:[NSString stringWithUTF8String:v[1]]];
    NSString *uti = [NSString stringWithUTF8String:v[2]];
    __block BOOL done = NO; __block NSError *err = nil;
    [[NSWorkspace sharedWorkspace] setDefaultApplicationAtURL:app
                                            toOpenContentType:[UTType typeWithIdentifier:uti]
                                            completionHandler:^(NSError *e) { err = e; done = YES; }];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!done && [limit timeIntervalSinceNow] > 0)
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    printf("%s -> %s\n", uti.UTF8String, err ? err.localizedDescription.UTF8String : "已設定");
  }
  return 0;
}
