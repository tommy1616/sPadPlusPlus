#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
int main(int c, const char **v) {
  @autoreleasepool {
    NSString *uti = c > 1 ? [NSString stringWithUTF8String:v[1]] : @"public.plain-text";
    if (@available(macOS 12.0, *)) {
      UTType *t = [UTType typeWithIdentifier:uti];
      NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenContentType:t];
      printf("%s -> %s\n", uti.UTF8String, u.path.UTF8String ?: "(none)");
    }
  }
  return 0;
}
