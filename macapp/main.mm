// macapp/main.mm — sPad++
//
// Notepad++ → macOS 移植 spike，第二階段：
//   [1] 分頁列 + session 還原
//   [2] 編碼偵測與轉換（Big5 / GB18030 / Shift-JIS / UTF-16 …）
//
// 編輯引擎：Scintilla (Cocoa) + Lexilla，原生 arm64。
// 這個檔案只有「殼」——這正是移植真正的工作量所在。

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <time.h>
#include <string.h>
#include <fnmatch.h>
#include <ctype.h>

#import "ScintillaView.h"
#import "Scintilla.h"
#import "ILexer.h"
#import "Lexilla.h"
#import "SciLexer.h"

#include "uchardet.h"

#define T(s) NSLocalizedString((s), nil)

//--------------------------------------------------------------------------------------------------
#pragma mark - 小工具

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

static NSString *human_bytes(unsigned long long n)
{
    if (n >= 1024ULL * 1024 * 1024) return [NSString stringWithFormat:@"%.2f GB", n / 1073741824.0];
    if (n >= 1024ULL * 1024)        return [NSString stringWithFormat:@"%.1f MB", n / 1048576.0];
    if (n >= 1024ULL)               return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    return [NSString stringWithFormat:@"%llu B", n];
}

static NSColor *hex_rgb(unsigned v)
{
    return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0
                               green:((v >> 8) & 0xFF) / 255.0
                                blue:(v & 0xFF) / 255.0 alpha:1.0];
}

static const char *lexer_for_path(NSString *path)
{
    NSString *ext = [[path pathExtension] lowercaseString];
    NSString *base = [[path lastPathComponent] lowercaseString];
    if ([base isEqualToString:@"makefile"] || [base isEqualToString:@"cmakelists.txt"]) return "makefile";
    if ([ext isEqualToString:@"c"] || [ext isEqualToString:@"h"] ||
        [ext isEqualToString:@"cpp"] || [ext isEqualToString:@"cxx"] ||
        [ext isEqualToString:@"cc"] || [ext isEqualToString:@"hpp"] ||
        [ext isEqualToString:@"hxx"] || [ext isEqualToString:@"mm"] ||
        [ext isEqualToString:@"m"] || [ext isEqualToString:@"js"] ||
        [ext isEqualToString:@"jsx"] || [ext isEqualToString:@"ts"] ||
        [ext isEqualToString:@"tsx"] || [ext isEqualToString:@"swift"] ||
        [ext isEqualToString:@"go"] || [ext isEqualToString:@"java"] ||
        [ext isEqualToString:@"cs"])  return "cpp";
    if ([ext isEqualToString:@"py"])   return "python";
    if ([ext isEqualToString:@"json"]) return "json";
    if ([ext isEqualToString:@"md"] || [ext isEqualToString:@"markdown"]) return "markdown";
    if ([ext isEqualToString:@"xml"] || [ext isEqualToString:@"html"] ||
        [ext isEqualToString:@"htm"])  return "hypertext";
    if ([ext isEqualToString:@"sh"] || [ext isEqualToString:@"zsh"] ||
        [ext isEqualToString:@"bash"]) return "bash";
    if ([ext isEqualToString:@"rs"])   return "rust";
    if ([ext isEqualToString:@"pl"] || [ext isEqualToString:@"pm"]) return "perl";
    if ([ext isEqualToString:@"rb"])   return "ruby";
    if ([ext isEqualToString:@"lua"])  return "lua";
    if ([ext isEqualToString:@"sql"])  return "sql";
    if ([ext isEqualToString:@"ini"] || [ext isEqualToString:@"conf"] ||
        [ext isEqualToString:@"properties"]) return "props";
    return "null";
}

static const char *cpp_keywords =
    "alignas alignof and and_eq asm auto bitand bitor bool break case catch char char8_t "
    "char16_t char32_t class compl concept const consteval constexpr constinit const_cast "
    "continue co_await co_return co_yield decltype default delete do double dynamic_cast "
    "else enum explicit export extern false float for friend goto if inline int long mutable "
    "namespace new noexcept not not_eq nullptr operator or or_eq private protected public "
    "register reinterpret_cast requires return short signed sizeof static static_assert "
    "static_cast struct switch template this thread_local throw true try typedef typeid "
    "typename union unsigned using virtual void volatile wchar_t while xor xor_eq "
    "include define ifdef ifndef endif pragma import interface implementation property "
    "synthesize autoreleasepool nil YES NO self super id SEL BOOL";

//--------------------------------------------------------------------------------------------------
#pragma mark - 編碼

// 常見可選編碼（給選單用）
static NSArray<NSString *> *common_encodings(void)
{
    return @[ @"UTF-8", @"UTF-16LE", @"UTF-16BE", @"Big5", @"GB18030", @"Shift_JIS",
              @"EUC-JP", @"EUC-KR", @"windows-1252", @"ISO-8859-1" ];
}

static NSString *canonical_charset(const char *raw)
{
    if (!raw) return @"UTF-8";
    NSString *s = [NSString stringWithUTF8String:raw];
    if (!s.length) return @"UTF-8";

    NSString *u = [s uppercaseString];
    if ([u containsString:@"UTF-8"] || [u containsString:@"ASCII"]) return @"UTF-8";
    if ([u containsString:@"UTF-16LE"]) return @"UTF-16LE";
    if ([u containsString:@"UTF-16BE"]) return @"UTF-16BE";
    if ([u containsString:@"UTF-16"])   return @"UTF-16LE";
    if ([u containsString:@"BIG5"])     return @"Big5";
    if ([u containsString:@"GB18030"] || [u containsString:@"GB2312"] || [u containsString:@"GBK"])
        return @"GB18030";
    if ([u containsString:@"SHIFT_JIS"] || [u containsString:@"SJIS"]) return @"Shift_JIS";
    if ([u containsString:@"EUC-JP"])   return @"EUC-JP";
    if ([u containsString:@"EUC-KR"])   return @"EUC-KR";
    if ([u containsString:@"EUC-TW"])   return @"EUC-TW";
    if ([u containsString:@"WINDOWS-1252"] || [u containsString:@"ISO-8859-1"] ||
        [u containsString:@"LATIN1"])   return @"windows-1252";
    return s;
}

static NSStringEncoding ns_encoding_for_name(NSString *name)
{
    if ([name isEqualToString:@"UTF-8"])     return NSUTF8StringEncoding;
    if ([name isEqualToString:@"UTF-16LE"])  return NSUTF16LittleEndianStringEncoding;
    if ([name isEqualToString:@"UTF-16BE"])  return NSUTF16BigEndianStringEncoding;
    if ([name isEqualToString:@"windows-1252"]) return NSWindowsCP1252StringEncoding;

    CFStringEncoding cf = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)name);
    if (cf == kCFStringEncodingInvalidId) return 0;
    return CFStringConvertEncodingToNSStringEncoding(cf);
}

typedef struct {
    BOOL     hasBOM;
    NSString *name;      // "UTF-8" / "Big5" / ...
} EncDetection;

static EncDetection detect_encoding(NSData *data)
{
    EncDetection r = { NO, @"UTF-8" };
    const unsigned char *b = (const unsigned char *)[data bytes];
    NSUInteger n = [data length];

    if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) { r.hasBOM = YES; r.name = @"UTF-8"; return r; }
    if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE) { r.hasBOM = YES; r.name = @"UTF-16LE"; return r; }
    if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF) { r.hasBOM = YES; r.name = @"UTF-16BE"; return r; }
    if (n == 0) return r;

    // uchardet 只需要前面一小段（64 KB 足夠）
    NSUInteger probe = n < 65536 ? n : 65536;
    uchardet_t ud = uchardet_new();
    if (ud)
    {
        if (uchardet_handle_data(ud, (const char *)b, probe) == 0)
        {
            uchardet_data_end(ud);
            const char *cs = uchardet_get_charset(ud);
            if (cs && *cs) r.name = canonical_charset(cs);
        }
        uchardet_delete(ud);
    }

    // 純 ASCII 會被判成 ASCII；用 UTF-8 存比較安全
    if ([r.name isEqualToString:@"ASCII"]) r.name = @"UTF-8";
    return r;
}

// 依編碼解碼成 UTF-8 bytes（Scintilla 內部一律 UTF-8）
static NSData *decode_to_utf8(NSData *raw, NSString *encName, BOOL hasBOM)
{
    NSUInteger skip = 0;
    if (hasBOM)
    {
        if ([encName isEqualToString:@"UTF-8"]) skip = 3;
        else if ([encName isEqualToString:@"UTF-16LE"] || [encName isEqualToString:@"UTF-16BE"]) skip = 2;
    }

    NSData *payload = skip ? [raw subdataWithRange:NSMakeRange(skip, [raw length] - skip)] : raw;

    if ([encName isEqualToString:@"UTF-8"])
        return payload;                       // 快路徑：完全不轉換

    NSStringEncoding nsEnc = ns_encoding_for_name(encName);
    NSString *s = nsEnc ? [[NSString alloc] initWithData:payload encoding:nsEnc] : nil;
    if (!s)  // 解不開就用損失轉換硬解，至少讓使用者看到內容
        s = [[NSString alloc] initWithData:payload encoding:NSISOLatin1StringEncoding];

    NSData *utf8 = [s dataUsingEncoding:NSUTF8StringEncoding];
    return utf8 ?: [NSData data];
}

static NSData *bom_for(NSString *encName)
{
    if ([encName isEqualToString:@"UTF-8"])    return [NSData dataWithBytes:"\xEF\xBB\xBF" length:3];
    if ([encName isEqualToString:@"UTF-16LE"]) return [NSData dataWithBytes:"\xFF\xFE" length:2];
    if ([encName isEqualToString:@"UTF-16BE"]) return [NSData dataWithBytes:"\xFE\xFF" length:2];
    return [NSData data];
}

// 換行偵測
static NSString *detect_eol(NSData *data)
{
    const char *b = (const char *)[data bytes];
    NSUInteger n = MIN([data length], (NSUInteger)262144);
    NSUInteger crlf = 0, lf = 0, cr = 0;
    for (NSUInteger i = 0; i < n; i++)
    {
        if (b[i] == '\r')
        {
            if (i + 1 < n && b[i + 1] == '\n') { crlf++; i++; }
            else cr++;
        }
        else if (b[i] == '\n') lf++;
    }
    if (crlf >= lf && crlf >= cr) return crlf ? @"CRLF" : @"LF";
    return (lf >= cr) ? @"LF" : @"CR";
}

static NSData *normalize_eol(NSData *utf8, NSString *eol)
{
    if (!utf8.length) return utf8;
    NSString *s = [[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding];
    if (!s) return utf8;

    NSString *target = [eol isEqualToString:@"CRLF"] ? @"\r\n" : ([eol isEqualToString:@"CR"] ? @"\r" : @"\n");
    if ([eol isEqualToString:@"LF"] && [s rangeOfString:@"\r"].location == NSNotFound) return utf8;
    if ([eol isEqualToString:@"CRLF"] && [s rangeOfString:@"\r\n"].location != NSNotFound &&
        [s rangeOfString:@"\n"].location == [s rangeOfString:@"\r\n"].location) return utf8;

    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\r"   withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    if (![target isEqualToString:@"\n"])
        [m replaceOccurrencesOfString:@"\n" withString:target options:0 range:NSMakeRange(0, m.length)];
    return [m dataUsingEncoding:NSUTF8StringEncoding];
}

//--------------------------------------------------------------------------------------------------
#pragma mark - 文件

@interface Doc : NSObject
@property (nonatomic, copy)   NSString *path;         // nil = 未命名
@property (nonatomic, strong) ScintillaView *view;
@property (nonatomic, copy)   NSString *encoding;
@property (nonatomic, copy)   NSString *eol;
@property (nonatomic)         BOOL hasBOM;
@property (nonatomic)         long caret;
@property (nonatomic)         long firstVisibleLine;
@property (nonatomic)         BOOL metaDirty;      // 只改編碼/EOL、還沒改內容時用
@property (nonatomic, copy)   NSString *lexerName;  // 目前使用中的 Lexilla lexer

- (NSString *)title;
- (BOOL)isDirty;
@end

@implementation Doc
- (NSString *)title { return self.path ? [[self.path lastPathComponent] copy] : T(@"未命名"); }
- (BOOL)isDirty   { return self.metaDirty || [self.view getGeneralProperty:SCI_GETMODIFY] != 0; }
@end

@class TabBarView, AppDelegate;

@protocol TabBarDelegate <NSObject>
- (void)tabBar:(TabBarView *)bar didSelect:(NSInteger)index;
- (void)tabBar:(TabBarView *)bar didClose:(NSInteger)index;
- (void)tabBar:(TabBarView *)bar didMoveFrom:(NSInteger)from to:(NSInteger)to;
- (void)tabBarDidRequestNewTab:(TabBarView *)bar;
@end

//--------------------------------------------------------------------------------------------------
#pragma mark - 分頁列（可拖曳排序、可橫向捲動）

@interface TabBarView : NSView
@property (nonatomic, weak)   id<TabBarDelegate> delegate;
@property (nonatomic, strong) NSArray<Doc *> *docs;
@property (nonatomic)         NSInteger selectedIndex;
@property (nonatomic)         BOOL dark;
- (void)ensureVisibleIndex:(NSInteger)index;
@end

@implementation TabBarView
{
    NSInteger _hoverClose;
    NSInteger _dragFrom;
    CGFloat   _dragStartX;
    BOOL      _dragging;
    CGFloat   _scrollX;
}

- (BOOL)isFlipped { return YES; }

- (CGFloat)widthForDoc:(Doc *)d
{
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12] };
    CGFloat w = [[d title] sizeWithAttributes:attrs].width + 46;
    if ([d isDirty]) w += 14;
    return MAX(120.0, MIN(w, 300.0));
}

- (CGFloat)contentWidth
{
    CGFloat x = 0;
    for (Doc *d in self.docs) x += [self widthForDoc:d];
    return x + 36;                       // 「＋」
}

- (void)ensureVisibleIndex:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)self.docs.count) return;

    CGFloat x = 0;
    for (NSInteger i = 0; i < index; i++) x += [self widthForDoc:self.docs[i]];
    CGFloat w = [self widthForDoc:self.docs[index]];
    CGFloat vw = self.bounds.size.width;

    if (x - _scrollX < 0)                _scrollX = x;
    else if (x + w - _scrollX > vw)      _scrollX = x + w - vw;

    CGFloat maxX = MAX(0, [self contentWidth] - vw);
    _scrollX = MIN(MAX(0, _scrollX), maxX);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    NSColor *barBg = self.dark ? hex_rgb(0x252526) : hex_rgb(0xECECEC);
    [barBg setFill];
    NSRectFill(self.bounds);

    CGFloat x = -_scrollX;
    CGFloat h = self.bounds.size.height;

    for (NSUInteger i = 0; i < self.docs.count; i++)
    {
        Doc *d = self.docs[i];
        CGFloat w = [self widthForDoc:d];
        NSRect tabRect = NSMakeRect(x, 0, w, h);

        if (NSMaxX(tabRect) > 0 && tabRect.origin.x < self.bounds.size.width)
        {
            BOOL sel = ((NSInteger)i == self.selectedIndex);
            NSColor *fill = sel ? (self.dark ? hex_rgb(0x1E1E1E) : [NSColor whiteColor])
                                : (self.dark ? hex_rgb(0x2D2D2D) : hex_rgb(0xE0E0E0));
            [fill setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tabRect, 2, 3)
                                             xRadius:5 yRadius:5] fill];

            NSColor *fg = sel ? (self.dark ? hex_rgb(0xD4D4D4) : hex_rgb(0x1F1F1F))
                              : (self.dark ? hex_rgb(0x9A9A9A) : hex_rgb(0x666666));
            NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
            [ps setLineBreakMode:NSLineBreakByTruncatingMiddle];
            NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12],
                                     NSForegroundColorAttributeName: fg,
                                     NSParagraphStyleAttributeName: ps };
            NSString *title = [d title];
            if ([d isDirty]) title = [title stringByAppendingString:@" ●"];
            [title drawInRect:NSMakeRect(x + 12, (h - 16) / 2.0, w - 40, 16) withAttributes:attrs];

            NSRect closeRect = NSMakeRect(x + w - 22, (h - 14) / 2.0, 14, 14);
            NSColor *closeFg = ((NSInteger)i == _hoverClose)
                ? (self.dark ? hex_rgb(0xE8E8E8) : hex_rgb(0x000000))
                : (self.dark ? hex_rgb(0x808080) : hex_rgb(0x999999));
            [@"✕" drawInRect:closeRect withAttributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11],
                                                         NSForegroundColorAttributeName: closeFg }];

            if (sel)
            {
                [[NSColor controlAccentColor] setFill];
                NSRectFill(NSMakeRect(x + 2, h - 2, w - 4, 2));
            }
        }
        x += w;
    }

    if (x < self.bounds.size.width)
    {
        [@"＋" drawInRect:NSMakeRect(x + 8, (h - 18) / 2.0, 22, 18)
           withAttributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:15],
                             NSForegroundColorAttributeName: (self.dark ? hex_rgb(0x9A9A9A) : hex_rgb(0x777777)) }];
    }
}

- (NSInteger)indexAtPoint:(NSPoint)p closeArea:(BOOL *)isClose
{
    CGFloat x = -_scrollX;
    for (NSUInteger i = 0; i < self.docs.count; i++)
    {
        CGFloat w = [self widthForDoc:self.docs[i]];
        if (p.x >= x && p.x < x + w)
        {
            if (isClose) *isClose = (p.x > x + w - 26);
            return (NSInteger)i;
        }
        x += w;
    }
    if (isClose) *isClose = NO;
    return -1;
}

- (void)mouseDown:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];

    // 「＋」按鈕：單擊就新增
    CGFloat xEnd = -_scrollX;
    for (Doc *d in self.docs) xEnd += [self widthForDoc:d];
    if (NSPointInRect(p, NSMakeRect(xEnd + 2, 0, 34, self.bounds.size.height)))
    {
        [self.delegate tabBarDidRequestNewTab:self];
        return;
    }

    BOOL isClose = NO;
    NSInteger i = [self indexAtPoint:p closeArea:&isClose];

    if (i < 0)
    {
        // 空白處要雙擊才會新增分頁（避免誤觸）
        if (e.clickCount == 2) [self.delegate tabBarDidRequestNewTab:self];
        return;
    }
    if (isClose)
    {
        [self.delegate tabBar:self didClose:i];
        return;
    }

    _dragFrom = i;
    _dragStartX = p.x;
    _dragging = NO;

    if (i != self.selectedIndex)
        [self.delegate tabBar:self didSelect:i];
}

- (void)mouseDragged:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    if (!_dragging && fabs(p.x - _dragStartX) < 8) return;
    _dragging = YES;

    BOOL isClose = NO;
    NSInteger i = [self indexAtPoint:p closeArea:&isClose];
    if (i >= 0 && i != _dragFrom)
    {
        [self.delegate tabBar:self didMoveFrom:_dragFrom to:i];
        _dragFrom = i;
    }
}

- (void)mouseUp:(NSEvent *)e { _dragging = NO; }

- (void)scrollWheel:(NSEvent *)e
{
    CGFloat total = [self contentWidth];
    CGFloat maxX = MAX(0, total - self.bounds.size.width);
    if (maxX <= 0) return;

    CGFloat d = e.scrollingDeltaX;
    if (fabs(e.scrollingDeltaY) > fabs(d) && (e.modifierFlags & NSEventModifierFlagShift))
        d = e.scrollingDeltaY;

    _scrollX = MIN(MAX(0, _scrollX - d), maxX);
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    BOOL isClose = NO;
    NSInteger i = [self indexAtPoint:p closeArea:&isClose];
    NSInteger hover = (i >= 0 && isClose) ? i : -1;
    if (hover != _hoverClose) { _hoverClose = hover; [self setNeedsDisplay:YES]; }
}

- (void)updateTrackingAreas
{
    for (NSTrackingArea *a in [self trackingAreas]) [self removeTrackingArea:a];
    NSTrackingArea *t = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                       owner:self userInfo:nil];
    [self addTrackingArea:t];
}
@end

//--------------------------------------------------------------------------------------------------
#pragma mark - 尋找 / 取代 / 檔案中尋找

typedef NS_ENUM(NSInteger, FPMode) { FPModeFind = 0, FPModeReplace = 1, FPModeFiles = 2 };

typedef struct {
    BOOL matchCase;
    BOOL wholeWord;
    BOOL regex;
    BOOL wrap;
} FindOptions;

#define INDIC_FIND 31
#define INDIC_WORD 30

#define MARK_BOOKMARK 24
#define MARK_MATCH    22   // 25 以上會被 Scintilla 當成摺疊標記

static NSTextField *fp_label(NSString *s)
{
    NSTextField *l = [[NSTextField alloc] init];
    [l setStringValue:s];
    [l setBezeled:NO];
    [l setDrawsBackground:NO];
    [l setEditable:NO];
    [l setSelectable:NO];
    [l setFont:[NSFont systemFontOfSize:12]];
    [l setTextColor:[NSColor secondaryLabelColor]];
    return l;
}

@protocol FPHost <NSObject>
- (void)fpOptionsChanged;
- (void)fpFindNext;
- (void)fpFindPrev;
- (void)fpReplaceOne;
- (void)fpReplaceAll;
- (void)fpRunFindInFiles;
- (void)fpPanelClosed;
- (void)fpReveal:(NSString *)path line:(NSInteger)line;
@end

@interface FindPanel : NSPanel <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak)   id<FPHost> host;
@property (nonatomic)         FPMode mode;

@property (nonatomic, strong) NSSegmentedControl *seg;
@property (nonatomic, strong) NSTextField *findLabel, *replaceLabel, *dirLabel, *filterLabel;
@property (nonatomic, strong) NSTextField *findField, *replaceField, *dirField, *filterField;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *caseCheck, *wordCheck, *regexCheck, *wrapCheck;
@property (nonatomic, strong) NSButton *prevBtn, *nextBtn, *repBtn, *repAllBtn, *goBtn, *closeBtn, *browseBtn, *histBtn;
@property (nonatomic, strong) NSScrollView *tableScroll;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSArray *resultItems;
@property (nonatomic, strong) NSMutableArray *history;

- (instancetype)initWithHost:(id<FPHost>)host;
- (void)showMode:(FPMode)mode inWindow:(NSWindow *)main;
- (void)setStatus:(NSString *)text error:(BOOL)isError;
@end

@implementation FindPanel
{
    BOOL    _placed;
    NSPoint _savedOrigin;
    BOOL    _hasSavedOrigin;
}

static NSString *const kFPOriginX = @"FindPanelOriginX";
static NSString *const kFPOriginY = @"FindPanelOriginY";

- (instancetype)initWithHost:(id<FPHost>)host
{
    self = [super initWithContentRect:NSMakeRect(0, 0, 660, 172)
                            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow)
                              backing:NSBackingStoreBuffered defer:NO];
    if (self)
    {
        _host = host;
        _history = [NSMutableArray array];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if ([ud objectForKey:kFPOriginX] && [ud objectForKey:kFPOriginY])
        {
            _savedOrigin = NSMakePoint([ud doubleForKey:kFPOriginX], [ud doubleForKey:kFPOriginY]);
            _hasSavedOrigin = YES;
        }
        [self setReleasedWhenClosed:NO];
        [self setTitle:T(@"尋找")];
        [self setFloatingPanel:YES];
        [self setLevel:NSFloatingWindowLevel];
        [self setDelegate:(id<NSWindowDelegate>)self];
        [self setCollectionBehavior:NSWindowCollectionBehaviorMoveToActiveSpace];
        [self buildUI];
        [self setMode:FPModeFind];
    }
    return self;
}

- (void)buildUI
{
    NSView *cv = [self contentView];

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:cv.bounds];
    [bg setMaterial:NSVisualEffectMaterialWindowBackground];
    [bg setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
    [bg setState:NSVisualEffectStateActive];
    [bg setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [cv addSubview:bg];

    // 模式切換
    _seg = [NSSegmentedControl segmentedControlWithLabels:@[ T(@"尋找"), T(@"取代"), T(@"檔案中尋找") ]
                                             trackingMode:NSSegmentSwitchTrackingSelectOne
                                                   target:self action:@selector(modeChanged:)];
    [_seg setSelectedSegment:0];
    [cv addSubview:_seg];

    // 尋找
    _findLabel = fp_label(T(@"尋找："));
    _findField = [[NSTextField alloc] init];
    [_findField setFont:[NSFont systemFontOfSize:13]];
    [_findField setPlaceholderString:T(@"輸入要尋找的文字…")];
    [_findField setDelegate:self];
    [_findField setTarget:self];
    [_findField setAction:@selector(enterPressed:)];
    _histBtn = [NSButton buttonWithTitle:@"▾" target:self action:@selector(showHistory:)];
    [_histBtn setBezelStyle:NSBezelStyleInline];
    [cv addSubview:_findLabel]; [cv addSubview:_findField]; [cv addSubview:_histBtn];

    // 取代
    _replaceLabel = fp_label(T(@"取代為："));
    _replaceField = [[NSTextField alloc] init];
    [_replaceField setFont:[NSFont systemFontOfSize:13]];
    [_replaceField setPlaceholderString:T(@"留空表示刪除")];
    [_replaceField setDelegate:self];
    [cv addSubview:_replaceLabel]; [cv addSubview:_replaceField];

    // 選項
    _caseCheck  = [NSButton checkboxWithTitle:T(@"大小寫須相符") target:self action:@selector(optionChanged:)];
    _wordCheck  = [NSButton checkboxWithTitle:T(@"全字拼寫")     target:self action:@selector(optionChanged:)];
    _regexCheck = [NSButton checkboxWithTitle:T(@"正規表示式")   target:self action:@selector(optionChanged:)];
    _wrapCheck  = [NSButton checkboxWithTitle:T(@"循環")         target:self action:@selector(optionChanged:)];
    [_wrapCheck setState:NSControlStateValueOn];
    for (NSButton *b in @[ _caseCheck, _wordCheck, _regexCheck, _wrapCheck ])
    {
        [b setFont:[NSFont systemFontOfSize:11]];
        [cv addSubview:b];
    }

    // 狀態
    _statusLabel = [[NSTextField alloc] init];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setFont:[NSFont systemFontOfSize:11]];
    [_statusLabel setTextColor:[NSColor secondaryLabelColor]];
    [_statusLabel setStringValue:@""];
    [cv addSubview:_statusLabel];

    // 按鈕
    _prevBtn = [NSButton buttonWithTitle:T(@"上一個") target:self action:@selector(prevClicked:)];
    _nextBtn = [NSButton buttonWithTitle:T(@"下一個") target:self action:@selector(nextClicked:)];
    _repBtn  = [NSButton buttonWithTitle:T(@"取代")   target:self action:@selector(replaceClicked:)];
    _repAllBtn = [NSButton buttonWithTitle:T(@"全部取代") target:self action:@selector(replaceAllClicked:)];
    _goBtn   = [NSButton buttonWithTitle:T(@"開始搜尋") target:self action:@selector(goClicked:)];
    _closeBtn = [NSButton buttonWithTitle:T(@"關閉") target:self action:@selector(closeClicked:)];
    for (NSButton *b in @[ _prevBtn, _nextBtn, _repBtn, _repAllBtn, _goBtn, _closeBtn ])
    {
        [b setBezelStyle:NSBezelStyleRounded];
        [b setFont:[NSFont systemFontOfSize:12]];
        [cv addSubview:b];
    }
    if (@available(macOS 11.0, *))
    {
        [_prevBtn setImage:[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:nil]];
        [_nextBtn setImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil]];
        [_prevBtn setImagePosition:NSImageLeft];
        [_nextBtn setImagePosition:NSImageLeft];
    }
    [_repBtn setKeyEquivalent:@"\r"];

    // 檔案中尋找：路徑 / 篩選
    _dirLabel = fp_label(T(@"資料夾："));
    _dirField = [[NSTextField alloc] init];
    [_dirField setFont:[NSFont systemFontOfSize:12]];
    [_dirField setPlaceholderString:@"~/Documents"];
    _browseBtn = [NSButton buttonWithTitle:T(@"瀏覽…") target:self action:@selector(browseClicked:)];
    [_browseBtn setBezelStyle:NSBezelStyleRounded];
    [_browseBtn setFont:[NSFont systemFontOfSize:11]];

    _filterLabel = fp_label(T(@"篩選："));
    _filterField = [[NSTextField alloc] init];
    [_filterField setFont:[NSFont systemFontOfSize:12]];
    [_filterField setStringValue:@"*.txt;*.md;*.c;*.cpp;*.h;*.mm;*.py;*.json"];
    [_filterField setPlaceholderString:T(@"*.txt;*.md（分號分隔）")];
    [cv addSubview:_dirLabel]; [cv addSubview:_dirField]; [cv addSubview:_browseBtn];
    [cv addSubview:_filterLabel]; [cv addSubview:_filterField];

    // 結果表
    _table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 600, 200)];
    NSTableColumn *c1 = [[NSTableColumn alloc] initWithIdentifier:@"loc"];
    [[c1 headerCell] setStringValue:T(@"位置")];
    [c1 setWidth:250];
    NSTableColumn *c2 = [[NSTableColumn alloc] initWithIdentifier:@"text"];
    [[c2 headerCell] setStringValue:T(@"內容")];
    [c2 setWidth:370];
    [_table addTableColumn:c1];
    [_table addTableColumn:c2];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setRowHeight:18];
    [_table setUsesAlternatingRowBackgroundColors:YES];
    [_table setAllowsMultipleSelection:NO];
    [_table setTarget:self];
    [_table setDoubleAction:@selector(rowDoubleClicked:)];

    _tableScroll = [[NSScrollView alloc] init];
    [_tableScroll setDocumentView:_table];
    [_tableScroll setHasVerticalScroller:YES];
    [_tableScroll setBorderType:NSBezelBorder];
    [_tableScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [cv addSubview:_tableScroll];
}

- (CGFloat)contentHeightForMode
{
    if (_mode == FPModeReplace) return 184;
    if (_mode == FPModeFiles)   return 470;
    return 152;
}

- (void)resizeToMode
{
    CGFloat h = [self contentHeightForMode];
    NSRect content = NSMakeRect(0, 0, 660, h);
    NSRect frame = [self frameRectForContentRect:content];

    NSRect cur = self.frame;
    frame.origin.x = cur.origin.x;
    frame.origin.y = NSMaxY(cur) - frame.size.height;
    [self setFrame:frame display:YES animate:NO];
}

- (void)layoutUI
{
    NSView *cv = [self contentView];
    CGFloat W = cv.bounds.size.width;
    CGFloat H = cv.bounds.size.height;
    CGFloat m = 16;

    BOOL files = (_mode == FPModeFiles);
    BOOL repl  = (_mode == FPModeReplace);

    CGFloat ySeg    = H - 10 - 24;
    CGFloat yFind   = H - 42 - 24;
    CGFloat yReplace= H - 74 - 24;
    CGFloat yOptions= H - (repl ? 106 : 74) - 18;
    CGFloat yDir    = H - 106 - 24;
    CGFloat yFilter = H - 138 - 24;
    CGFloat yStatus = H - (files ? 166 : (repl ? 130 : 98)) - 16;

    [_seg setFrame:NSMakeRect(m, ySeg, 250, 24)];

    [_findLabel setFrame:NSMakeRect(m, yFind + 3, 52, 18)];
    [_findField setFrame:NSMakeRect(m + 54, yFind, W - 2 * m - 54 - 26, 24)];
    [_histBtn setFrame:NSMakeRect(W - m - 24, yFind + 2, 24, 20)];

    [_replaceLabel setHidden:!repl];
    [_replaceField setHidden:!repl];
    [_replaceLabel setFrame:NSMakeRect(m, yReplace + 3, 60, 18)];
    [_replaceField setFrame:NSMakeRect(m + 62, yReplace, W - 2 * m - 62, 24)];

    CGFloat cx = m;
    for (NSButton *b in @[ _caseCheck, _wordCheck, _regexCheck, _wrapCheck ])
    {
        CGFloat w = [b intrinsicContentSize].width + 4;
        [b setFrame:NSMakeRect(cx, yOptions, w, 18)];
        cx += w + 12;
    }

    [_dirLabel setHidden:!files]; [_dirField setHidden:!files]; [_browseBtn setHidden:!files];
    [_filterLabel setHidden:!files]; [_filterField setHidden:!files];
    [_dirLabel setFrame:NSMakeRect(m, yDir + 3, 56, 18)];
    [_dirField setFrame:NSMakeRect(m + 58, yDir, W - 2 * m - 58 - 76, 24)];
    [_browseBtn setFrame:NSMakeRect(W - m - 72, yDir, 72, 24)];
    [_filterLabel setFrame:NSMakeRect(m, yFilter + 3, 56, 18)];
    [_filterField setFrame:NSMakeRect(m + 58, yFilter, W - 2 * m - 58, 24)];

    [_statusLabel setFrame:NSMakeRect(m, yStatus, W - 2 * m, 16)];

    // ---- 按鈕列（由右而左）
    CGFloat btnY = 12, btnH = 26;
    CGFloat rx = W - m;

    [_closeBtn setHidden:NO];
    [_goBtn setHidden:!files];
    [_repAllBtn setHidden:!repl];
    [_repBtn setHidden:!repl];
    [_prevBtn setHidden:files];
    [_nextBtn setHidden:files];

    NSMutableArray<NSButton *> *right = [NSMutableArray arrayWithObject:_closeBtn];
    if (files) [right addObject:_goBtn];
    if (repl)  [right addObject:_repAllBtn];

    for (NSButton *b in right)
    {
        CGFloat w = [b intrinsicContentSize].width + 20;
        rx -= w;
        [b setFrame:NSMakeRect(rx, btnY, w, btnH)];
        rx -= 8;
    }

    if (repl)
    {
        CGFloat w = [_repBtn intrinsicContentSize].width + 20;
        rx -= w;
        [_repBtn setFrame:NSMakeRect(rx, btnY, w, btnH)];
        rx -= 8;
    }

    CGFloat bx = m;
    for (NSButton *b in @[ _prevBtn, _nextBtn ])
    {
        if (b.isHidden) continue;
        CGFloat w = [b intrinsicContentSize].width + 18;
        [b setFrame:NSMakeRect(bx, btnY, w, btnH)];
        bx += w + 8;
    }

    // ---- 結果表格
    [_tableScroll setHidden:!files];
    if (files)
        [_tableScroll setFrame:NSMakeRect(m, btnY + btnH + 8, W - 2 * m, yStatus - (btnY + btnH + 8) - 6)];
}

- (void)setMode:(FPMode)mode
{
    _mode = mode;
    [_seg setSelectedSegment:mode];
    [self resizeToMode];
    [self layoutUI];
    [self setTitle:(mode == FPModeFind ? T(@"尋找") : (mode == FPModeReplace ? T(@"取代") : T(@"檔案中尋找")))];
    [self focusFindField];
}

- (void)showMode:(FPMode)mode inWindow:(NSWindow *)main
{
    [self setMode:mode];

    if (!_placed)
    {
        if (_hasSavedOrigin)
        {
            NSRect f = self.frame;
            f.origin = _savedOrigin;
            [self setFrame:f display:NO];
            _placed = YES;
            [self keepOnScreen];
        }
        else
        {
            [self placeCenteredIn:main];
        }
    }
    else
    {
        [self keepOnScreen];
    }

    [self makeKeyAndOrderFront:nil];
    [self focusFindField];
}

- (void)keepOnScreen
{
    NSScreen *scr = [self screen] ?: [NSScreen mainScreen];
    NSRect v = [scr visibleFrame];
    NSRect f = self.frame;

    f.origin.x = MIN(MAX(f.origin.x, NSMinX(v)), NSMaxX(v) - f.size.width);
    f.origin.y = MIN(MAX(f.origin.y, NSMinY(v)), NSMaxY(v) - f.size.height);
    [self setFrame:f display:NO];
}

- (void)placeCenteredIn:(NSWindow *)main
{
    NSRect mf = main ? main.frame : [NSScreen mainScreen].visibleFrame;
    NSRect f = self.frame;

    f.origin.x = NSMidX(mf) - f.size.width / 2;
    f.origin.y = NSMaxY(mf) - f.size.height - 72;    // 貼近主視窗頂端（分頁列下方）
    [self setFrame:f display:NO];
    [self keepOnScreen];

    _placed = YES;
    [[NSUserDefaults standardUserDefaults] setDouble:f.origin.x forKey:kFPOriginX];
    [[NSUserDefaults standardUserDefaults] setDouble:f.origin.y forKey:kFPOriginY];
}

- (void)windowDidMove:(NSNotification *)n
{
    NSRect f = self.frame;
    [[NSUserDefaults standardUserDefaults] setDouble:f.origin.x forKey:kFPOriginX];
    [[NSUserDefaults standardUserDefaults] setDouble:f.origin.y forKey:kFPOriginY];
}

- (void)focusFindField
{
    [[self findField] becomeFirstResponder];
    [[self findField] selectText:nil];
}

- (void)modeChanged:(id)sender
{
    [self setMode:(FPMode)[_seg selectedSegment]];
    [_host fpOptionsChanged];
}

- (void)optionChanged:(id)sender { [_host fpOptionsChanged]; }
- (void)enterPressed:(id)sender   { [_host fpFindNext]; }
- (void)prevClicked:(id)sender    { [_host fpFindPrev]; }
- (void)nextClicked:(id)sender    { [_host fpFindNext]; }
- (void)replaceClicked:(id)sender { [_host fpReplaceOne]; }
- (void)replaceAllClicked:(id)sender { [_host fpReplaceAll]; }
- (void)goClicked:(id)sender      { [_host fpRunFindInFiles]; }
- (void)closeClicked:(id)sender   { [self orderOut:nil]; [_host fpPanelClosed]; }

- (void)cancelOperation:(id)sender { [self closeClicked:nil]; }

- (void)windowWillClose:(NSNotification *)n { [_host fpPanelClosed]; }

- (void)controlTextDidChange:(NSNotification *)n { [_host fpOptionsChanged]; }

- (void)showHistory:(id)sender
{
    if (!_history.count) { NSBeep(); return; }
    NSMenu *menu = [[NSMenu alloc] init];
    for (NSString *s in [_history reverseObjectEnumerator])
    {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:s action:@selector(pickHistory:) keyEquivalent:@""];
        [it setTarget:self];
        [it setRepresentedObject:s];
        [menu addItem:it];
    }
    [menu popUpMenuPositioningItem:nil atLocation:[self convertPointFromScreen:NSMakePoint(0, 0)] inView:nil];
}

- (void)pickHistory:(NSMenuItem *)it
{
    [_findField setStringValue:[it representedObject]];
    [_host fpOptionsChanged];
}

- (void)addHistory:(NSString *)s
{
    if (!s.length) return;
    [_history removeObject:s];
    [_history addObject:s];
    while (_history.count > 15) [_history removeObjectAtIndex:0];
}

- (void)browseClicked:(id)sender
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setCanChooseDirectories:YES];
    [p setCanChooseFiles:NO];
    if ([p runModal] == NSModalResponseOK)
        [_dirField setStringValue:[[p URL] path]];
}

- (void)setStatus:(NSString *)text error:(BOOL)isError
{
    if (getenv("FPDEBUG")) { fprintf(stderr, "setStatus in  ptr=%p text=[%s]\n", (__bridge void *)_statusLabel, [text UTF8String] ?: "(null)"); }
    [_statusLabel setStringValue:text ?: @""];
    if (getenv("FPDEBUG")) { fprintf(stderr, "setStatus out ptr=%p val=[%s]\n", (__bridge void *)_statusLabel, [[_statusLabel stringValue] UTF8String] ?: "(null)"); }
    [_statusLabel setTextColor:isError ? [NSColor systemRedColor] : [NSColor secondaryLabelColor]];
}

- (void)setResultItems:(NSArray *)items
{
    _resultItems = [items copy];       // 直接寫 ivar，避免與 property setter 遞迴
    [_table reloadData];
}

#pragma mark 表格

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.resultItems.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)self.resultItems.count) return nil;
    NSDictionary *it = self.resultItems[row];

    NSTextField *tf = [tv makeViewWithIdentifier:[col identifier] owner:self];
    if (!tf)
    {
        tf = [[NSTextField alloc] init];
        [tf setIdentifier:[col identifier]];
        [tf setBordered:NO];
        [tf setEditable:NO];
        [tf setDrawsBackground:NO];
        [tf setFont:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]];
        [tf setLineBreakMode:NSLineBreakByTruncatingTail];
    }
    if ([[col identifier] isEqualToString:@"loc"])
    {
        [tf setStringValue:[NSString stringWithFormat:@"%@:%ld",
                            it[@"rel"] ?: [[it[@"path"] lastPathComponent] description],
                            [it[@"line"] longValue]]];
        [tf setTextColor:[NSColor secondaryLabelColor]];
    }
    else
    {
        [tf setStringValue:[it[@"text"] description]];
        [tf setTextColor:[NSColor labelColor]];
    }
    return tf;
}

- (void)rowDoubleClicked:(id)sender
{
    NSInteger row = [_table clickedRow];
    if (row < 0 || row >= (NSInteger)self.resultItems.count) return;
    NSDictionary *it = self.resultItems[row];
    [_host fpReveal:it[@"path"] line:[it[@"line"] longValue]];
}

@end


//--------------------------------------------------------------------------------------------------
#pragma mark 事件記錄（抓閃退用）

static void npp_log(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss.SSS"];
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];

    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES) firstObject]
                     stringByAppendingPathComponent:@"sPad++"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:@"events.log"];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh)
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void npp_exception_handler(NSException *e)
{
    npp_log(@"UNCAUGHT %@: %@\n%@", [e name], [e reason],
            [[e callStackSymbols] componentsJoinedByString:@"\n"]);
}

//--------------------------------------------------------------------------------------------------
#pragma mark - 背景搜尋工作

@interface FIFJob : NSObject
@property (atomic) BOOL cancelled;
@end

@implementation FIFJob
@end


//--------------------------------------------------------------------------------------------------
#pragma mark - 主題（Notepad++ themes/*.xml 相容）

static NSColor *theme_color(NSString *hex, NSColor *fallback)
{
    if (hex.length < 6) return fallback;
    unsigned v = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&v]) return fallback;
    return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0
                               green:((v >> 8) & 0xFF) / 255.0
                                blue:(v & 0xFF) / 255.0 alpha:1.0];
}

@interface Theme : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSDictionary *globals;   // widget 名稱 -> @{fg,bg}
@property (nonatomic, strong) NSDictionary *lexers;    // lexer 名稱 -> @{ @(styleID): @{fg,bg,style} }
@property (nonatomic) BOOL dark;

- (NSColor *)background;
- (NSColor *)foreground;
@end

@implementation Theme
- (NSColor *)background { return theme_color(self.globals[@"Default Style"][@"bg"], [NSColor textBackgroundColor]); }
- (NSColor *)foreground { return theme_color(self.globals[@"Default Style"][@"fg"], [NSColor textColor]); }
@end

@interface ThemeParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary *globals;
@property (nonatomic, strong) NSMutableDictionary *lexers;
@property (nonatomic, copy)   NSString *currentLexer;
@property (nonatomic, copy)   NSString *commentName;
@end

@implementation ThemeParser

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element
  namespaceURI:(NSString *)ns qualifiedName:(NSString *)qn attributes:(NSDictionary *)attrs
{
    if ([element isEqualToString:@"LexerType"])
    {
        self.currentLexer = attrs[@"name"];
        if (self.currentLexer) self.lexers[self.currentLexer] = [NSMutableDictionary dictionary];
    }
    else if ([element isEqualToString:@"WordsStyle"])
    {
        if (!self.currentLexer) return;
        NSString *sid = attrs[@"styleID"];
        if (!sid) return;
        NSMutableDictionary *st = [NSMutableDictionary dictionary];
        if (attrs[@"fgColor"]) st[@"fg"] = attrs[@"fgColor"];
        if (attrs[@"bgColor"]) st[@"bg"] = attrs[@"bgColor"];
        if (attrs[@"fontStyle"]) st[@"style"] = attrs[@"fontStyle"];
        self.lexers[self.currentLexer][@([sid intValue])] = st;
    }
    else if ([element isEqualToString:@"WidgetStyle"])
    {
        NSString *name = attrs[@"name"];
        if (!name) return;
        NSMutableDictionary *st = [NSMutableDictionary dictionary];
        if (attrs[@"fgColor"]) st[@"fg"] = attrs[@"fgColor"];
        if (attrs[@"bgColor"]) st[@"bg"] = attrs[@"bgColor"];
        self.globals[name] = st;
    }
}

- (void)parser:(NSXMLParser *)parser foundComment:(NSString *)comment
{
    NSString *prefix = @"sPad++ 內建主題：";
    NSString *t = [comment stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t hasPrefix:prefix]) self.commentName = [t substringFromIndex:prefix.length];
}

@end

@interface ThemeManager : NSObject
@property (nonatomic, strong) NSMutableArray<Theme *> *themes;
@property (nonatomic, strong) Theme *current;
+ (instancetype)shared;
- (void)reload;
- (BOOL)selectTheme:(NSString *)identifier;
- (NSString *)userThemeDirectory;
@property (nonatomic, copy) NSString *themeDirectory;
@end

@implementation ThemeManager

+ (instancetype)shared
{
    static ThemeManager *m = nil;
    if (!m) m = [[ThemeManager alloc] init];
    return m;
}

- (NSString *)userThemeDirectory
{
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    return [[dir stringByAppendingPathComponent:@"sPad++"] stringByAppendingPathComponent:@"themes"];
}

- (Theme *)loadThemeAtPath:(NSString *)path
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    ThemeParser *tp = [[ThemeParser alloc] init];
    tp.globals = [NSMutableDictionary dictionary];
    tp.lexers = [NSMutableDictionary dictionary];

    NSXMLParser *p = [[NSXMLParser alloc] initWithData:data];
    p.delegate = tp;
    if (![p parse]) return nil;

    if (tp.globals[@"Default Style"] == nil && tp.lexers.count == 0) return nil;

    Theme *t = [[Theme alloc] init];
    t.path = path;
    t.identifier = [[path lastPathComponent] stringByDeletingPathExtension];
    t.displayName = tp.commentName.length ? tp.commentName
                                          : [t.identifier stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    t.globals = tp.globals;
    t.lexers = tp.lexers;

    NSColor *bg = [t background];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    NSColor *rgb = [bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    [rgb getRed:&r green:&g blue:&b alpha:&a];
    t.dark = (0.299 * r + 0.587 * g + 0.114 * b) < 0.5;
    return t;
}

- (void)reload
{
    self.themes = [NSMutableArray array];

    NSString *bundled = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"Themes"];
    NSString *user = [self userThemeDirectory];

    // 先內建，再使用者（同名時使用者優先）
    NSMutableDictionary *byId = [NSMutableDictionary dictionary];
    for (NSString *dir in @[ bundled, user ])
    {
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL])
        {
            if (![[f pathExtension] isEqualToString:@"xml"]) continue;
            Theme *t = [self loadThemeAtPath:[dir stringByAppendingPathComponent:f]];
            if (t) byId[t.identifier] = t;
        }
    }

    self.themes = [[byId.allValues sortedArrayUsingComparator:^NSComparisonResult(Theme *a, Theme *b) {
        return [a.displayName compare:b.displayName];
    }] mutableCopy];

    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"ThemeName"];
    for (Theme *t in self.themes)
        if ([t.identifier isEqualToString:saved]) { self.current = t; break; }

    if (!self.current)
    {
        BOOL systemDark = NO;
        if (@available(macOS 10.14, *))
            systemDark = [[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:
                           @[ NSAppearanceNameDarkAqua, NSAppearanceNameAqua ]]
                          isEqualToString:NSAppearanceNameDarkAqua];
        NSString *want = systemDark ? @"ink" : @"mist";
        for (Theme *t in self.themes)
            if ([t.identifier isEqualToString:want]) { self.current = t; break; }
        if (!self.current) self.current = self.themes.firstObject;
    }

    [[NSUserDefaults standardUserDefaults] setObject:self.current.identifier forKey:@"ThemeName"];
}

- (BOOL)selectTheme:(NSString *)identifier
{
    for (Theme *t in self.themes)
    {
        if ([t.identifier isEqualToString:identifier])
        {
            self.current = t;
            [[NSUserDefaults standardUserDefaults] setObject:t.identifier forKey:@"ThemeName"];
            return YES;
        }
    }
    return NO;
}

@end

//--------------------------------------------------------------------------------------------------
#pragma mark - AppDelegate

@interface AppDelegate : NSObject <NSApplicationDelegate, TabBarDelegate, ScintillaNotificationProtocol, FPHost>
{
    NSWindow      *_window;
    TabBarView    *_tabBar;
    NSView        *_editorHost;
    NSView        *_statusBar;
    NSTextField   *_statusLeft;
    NSTextField   *_statusRight;
    NSMutableArray<Doc *> *_docs;
    NSInteger      _active;
    BOOL           _dark;
    BOOL           _bench;
    NSString      *_snapshotPath;
    BOOL           _saveTest;
    BOOL           _uiCheck;
    BOOL           _hideCheck;
    BOOL           _hidePanel;
    BOOL           _scrollBench;
    BOOL           _scrollStress;
    BOOL           _closeCheck;
    NSTimer       *_stressTimer;
    int            _stressTicks;
    BOOL           _editCheck;
    NSMutableArray *_openPaths;    // 命令列要開的檔
    double         _tLoad;
    double         _tStyle;
    FindPanel     *_findPanel;
    NSMutableArray *_findRanges;
    NSString       *_lastWord;
    NSString       *_lastStatusLeft;
    NSString       *_lastStatusRight;
    BOOL            _showWS;
    BOOL            _showEOL;
    NSMenu         *_themeMenu;
    NSMutableArray *_pendingOpen;
    NSMutableArray *_viewPool;
    id              _fifJob;
    NSUInteger      _fifGen;
    BOOL            _fifRunning;
}
@end

@implementation AppDelegate

//--------------------------------------------------------------------------------------------------
#pragma mark 啟動

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    NSSetUncaughtExceptionHandler(npp_exception_handler);
    [[ThemeManager shared] reload];
    npp_log(@"launch args=%@", [[[NSProcessInfo processInfo] arguments] componentsJoinedByString:@" "]);
    _docs = [NSMutableArray array];
    _openPaths = [NSMutableArray array];

    NSArray *args = [[NSProcessInfo processInfo] arguments];
    for (NSUInteger i = 1; i < args.count; i++)
    {
        NSString *a = args[i];
        if ([a isEqualToString:@"--bench"])          _bench = YES;
        else if ([a isEqualToString:@"--dark"])      _dark = YES;
        else if ([a isEqualToString:@"--snapshot"] && i + 1 < args.count) _snapshotPath = args[++i];
        else if ([a isEqualToString:@"--save-test"])  _saveTest = YES;
        else if ([a isEqualToString:@"--uicheck"])    _uiCheck = YES;
        else if ([a isEqualToString:@"--hidecheck"])  _hideCheck = YES;
        else if ([a isEqualToString:@"--hidepanel"])  _hidePanel = YES;
        else if ([a isEqualToString:@"--scrollbench"]) _scrollBench = YES;
        else if ([a isEqualToString:@"--scrollstress"]) _scrollStress = YES;
        else if ([a isEqualToString:@"--closecheck"]) _closeCheck = YES;
        else if ([a isEqualToString:@"--editcheck"])  _editCheck = YES;
        else if ([a hasPrefix:@"-AppleLanguages"] || [a hasPrefix:@"-AppleLocale"])
        {
            i++;   // 這是 NSUserDefaults 的參數，後面那個值不是檔案
        }
        else if ([a hasPrefix:@"-"]) { /* 其他 -開頭的參數忽略 */ }
        else [_openPaths addObject:a];
    }

    [self buildMenu];
    [self buildWindow];

    if (_bench)
    {
        for (NSString *p in _openPaths) [self openPath:[p stringByStandardizingPath]];
        if (!_docs.count) [self newDocument:nil];
    }
    else if (_openPaths.count)
    {
        for (NSString *p in _openPaths)
            [self openPath:[p stringByStandardizingPath]];
    }
    else if (_pendingOpen.count)
    {
        for (NSString *p in _pendingOpen) [self openPath:p];
    }
    else if (!_uiCheck && !_editCheck)
    {
        [self restoreSession];
        if (!_docs.count) [self newDocument:nil];
    }
    else
    {
        [self newDocument:nil];
    }

    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (_closeCheck)
        [self performSelector:@selector(doCloseCheck) withObject:nil afterDelay:0.8];
    else if (_scrollStress)
        [self performSelector:@selector(doScrollStress) withObject:nil afterDelay:0.8];
    else if (_scrollBench)
        [self performSelector:@selector(doScrollBench) withObject:nil afterDelay:0.8];
    else if (_editCheck)
        [self performSelector:@selector(doEditCheck) withObject:nil afterDelay:0.8];
    else if (_hideCheck)
        [self performSelector:@selector(doHideCheck) withObject:nil afterDelay:1.5];
    else if (_uiCheck)
        [self performSelector:@selector(doUICheck) withObject:nil afterDelay:1.2];
    else if (_snapshotPath)
        [self performSelector:@selector(doSnapshot) withObject:nil afterDelay:1.0];
    else if (_bench)
        [self performSelector:@selector(doBenchAndQuit) withObject:nil afterDelay:2.5];
}

- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)filenames
{
    for (NSString *p in filenames)
    {
        if (_docs) [self openPath:p];
        else
        {
            if (!_pendingOpen) _pendingOpen = [NSMutableArray array];
            [_pendingOpen addObject:p];
        }
    }
    [app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return YES; }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)s
{
    npp_log(@"shouldTerminate requested (automation=%d)", (int)(_bench || _snapshotPath || _uiCheck || _hideCheck));
    if (_bench || _snapshotPath || _uiCheck || _hideCheck || _editCheck || _scrollBench || _scrollStress || _closeCheck) return NSTerminateNow;   // 自動化模式不要跳存檔提示

    for (Doc *d in _docs)
    {
        if (![d isDirty]) continue;
        [self selectDoc:d];
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:[NSString stringWithFormat:T(@"「%@」有未儲存的變更。"), [d title]]];
        [a setInformativeText:T(@"關閉前要儲存嗎？")];
        [a addButtonWithTitle:T(@"儲存")];
        [a addButtonWithTitle:T(@"不儲存")];
        [a addButtonWithTitle:T(@"取消")];
        NSModalResponse r = [a runModal];
        if (r == NSAlertThirdButtonReturn) return NSTerminateCancel;
        if (r == NSAlertFirstButtonReturn) [self saveDocument:nil];
    }
    [self saveSession];
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)n
{
    npp_log(@"willTerminate");
    [self saveSession];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag
{
    npp_log(@"reopen requested (visibleWindows=%d)", (int)flag);
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return YES;
}

- (void)applicationDidHide:(NSNotification *)n   { npp_log(@"didHide"); }
- (void)applicationDidUnhide:(NSNotification *)n { npp_log(@"didUnhide"); }

//--------------------------------------------------------------------------------------------------
#pragma mark 視窗

- (void)buildWindow
{
    NSRect frame = NSMakeRect(0, 0, 1120, 740);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    _window = [[NSWindow alloc] initWithContentRect:frame styleMask:style
                                            backing:NSBackingStoreBuffered defer:NO];
    [_window setTitle:@"sPad++"];
    [_window setMinSize:NSMakeSize(640, 420)];
    [_window setReleasedWhenClosed:NO];   // ARC 下務必關閉，否則關窗會 over-release
    [_window center];

    NSView *content = [[NSView alloc] initWithFrame:frame];
    [content setAutoresizesSubviews:YES];
    [_window setContentView:content];

    CGFloat tabH = 32, statusH = 24;

    _tabBar = [[TabBarView alloc] initWithFrame:NSMakeRect(0, frame.size.height - tabH, frame.size.width, tabH)];
    [_tabBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [_tabBar setDelegate:self];
    [content addSubview:_tabBar];

    _editorHost = [[NSView alloc] initWithFrame:NSMakeRect(0, statusH, frame.size.width, frame.size.height - tabH - statusH)];
    [_editorHost setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [content addSubview:_editorHost];

    _statusBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, statusH)];
    [_statusBar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [content addSubview:_statusBar];

    _statusLeft = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 3, 700, 18)];
    [_statusLeft setEditable:NO]; [_statusLeft setBordered:NO]; [_statusLeft setDrawsBackground:NO];
    [_statusLeft setFont:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [_statusLeft setStringValue:T(@"就緒")];
    [_statusLeft setAutoresizingMask:NSViewWidthSizable];
    [_statusBar addSubview:_statusLeft];

    _statusRight = [[NSTextField alloc] initWithFrame:NSMakeRect(frame.size.width - 520, 3, 508, 18)];
    [_statusRight setEditable:NO]; [_statusRight setBordered:NO]; [_statusRight setDrawsBackground:NO];
    [_statusRight setFont:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [_statusRight setAlignment:NSTextAlignmentRight];
    [_statusRight setStringValue:@""];
    [_statusRight setAutoresizingMask:NSViewMinXMargin];
    [_statusBar addSubview:_statusRight];

    [self applyTheme:_dark];
}

- (void)buildMenu
{
    NSMenu *bar = [[NSMenu alloc] init];
    [NSApp setMainMenu:bar];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appItem setSubmenu:appMenu];
    [appMenu addItemWithTitle:T(@"關於 sPad++") action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:T(@"隱藏 sPad++") action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:T(@"結束 sPad++") action:@selector(terminate:) keyEquivalent:@"q"];

    // ---- File
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [bar addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:T(@"檔案")];
    [fileItem setSubmenu:fileMenu];
    [fileMenu addItemWithTitle:T(@"新增分頁") action:@selector(newDocument:) keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:T(@"開啟…") action:@selector(openDocument:) keyEquivalent:@"o"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:T(@"關閉分頁") action:@selector(closeActiveTab:) keyEquivalent:@"w"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:T(@"儲存") action:@selector(saveDocument:) keyEquivalent:@"s"];
    [fileMenu addItemWithTitle:T(@"另存新檔…") action:@selector(saveDocumentAs:) keyEquivalent:@"S"];
    [fileMenu addItemWithTitle:T(@"從磁碟重新載入") action:@selector(reloadDocument:) keyEquivalent:@"r"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:T(@"執行載入效能測試…") action:@selector(runBenchmark:) keyEquivalent:@"b"];

    // ---- Edit
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:T(@"編輯")];
    [editItem setSubmenu:editMenu];
    [editMenu addItemWithTitle:T(@"復原") action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:T(@"重做") action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:T(@"剪下") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:T(@"複製") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:T(@"貼上") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:T(@"全選") action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *mi;
    mi = [editMenu addItemWithTitle:T(@"尋找…") action:@selector(menuFind:) keyEquivalent:@"f"];
    [mi setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    mi = [editMenu addItemWithTitle:T(@"取代…") action:@selector(menuReplace:) keyEquivalent:@"f"];
    [mi setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
    mi = [editMenu addItemWithTitle:T(@"檔案中尋找…") action:@selector(menuFindInFiles:) keyEquivalent:@"f"];
    [mi setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:T(@"找下一個") action:@selector(menuFindNext:) keyEquivalent:@"g"];
    mi = [editMenu addItemWithTitle:T(@"找上一個") action:@selector(menuFindPrev:) keyEquivalent:@"g"];
    [mi setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:T(@"選取下一個相同") action:@selector(selectNextOccurrence:) keyEquivalent:@"d"];
    NSMenuItem *allOcc = [editMenu addItemWithTitle:T(@"選取全部相同") action:@selector(selectAllOccurrences:) keyEquivalent:@"l"];
    [allOcc setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
    NSMenuItem *acItem = [editMenu addItemWithTitle:T(@"文字自動完成") action:@selector(showAutoComplete:) keyEquivalent:@"\r"];
    [acItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    [editMenu addItem:[NSMenuItem separatorItem]];

    NSString *f2 = [NSString stringWithFormat:@"%C", (unichar)NSF2FunctionKey];
    NSMenuItem *bmItem = [editMenu addItemWithTitle:T(@"切換書籤") action:@selector(toggleBookmark:) keyEquivalent:f2];
    [bmItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    NSMenuItem *bnItem = [editMenu addItemWithTitle:T(@"下一個書籤") action:@selector(nextBookmark:) keyEquivalent:f2];
    [bnItem setKeyEquivalentModifierMask:0];
    NSMenuItem *bpItem = [editMenu addItemWithTitle:T(@"上一個書籤") action:@selector(prevBookmark:) keyEquivalent:f2];
    [bpItem setKeyEquivalentModifierMask:NSEventModifierFlagShift];

    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *markItem = [editMenu addItemWithTitle:T(@"標記全部符合") action:@selector(markAllMatches:) keyEquivalent:@"m"];
    [markItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
    NSMenuItem *clearItem = [editMenu addItemWithTitle:T(@"清除所有標記") action:@selector(clearMarks:) keyEquivalent:@"k"];
    [clearItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];

    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:T(@"跳至行…") action:@selector(goToLine:) keyEquivalent:@"l"];

    // ---- View
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [bar addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:T(@"顯示")];
    [viewItem setSubmenu:viewMenu];
    NSMenuItem *themeItem = [[NSMenuItem alloc] initWithTitle:T(@"主題") action:nil keyEquivalent:@""];
    _themeMenu = [[NSMenu alloc] initWithTitle:T(@"主題")];
    [themeItem setSubmenu:_themeMenu];
    [viewMenu addItem:themeItem];
    [self rebuildThemeMenu];
    [viewMenu addItemWithTitle:@"Toggle Line Numbers" action:@selector(toggleLineNumbers:) keyEquivalent:@""];
    [viewMenu addItemWithTitle:@"Toggle Word Wrap" action:@selector(toggleWrap:) keyEquivalent:@""];

    [viewMenu addItemWithTitle:T(@"顯示空白字元") action:@selector(toggleWhitespace:) keyEquivalent:@""];
    [viewMenu addItemWithTitle:T(@"顯示換行符號") action:@selector(toggleEOL:) keyEquivalent:@""];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:T(@"放大") action:@selector(zoomIn:) keyEquivalent:@"="];
    [viewMenu addItemWithTitle:T(@"縮小") action:@selector(zoomOut:) keyEquivalent:@"-"];
    [viewMenu addItemWithTitle:T(@"實際大小") action:@selector(zoomReset:) keyEquivalent:@"0"];

    NSMenuItem *eolItem = [[NSMenuItem alloc] initWithTitle:T(@"換行格式") action:nil keyEquivalent:@""];
    NSMenu *eolMenu = [[NSMenu alloc] initWithTitle:T(@"換行格式")];
    [eolItem setSubmenu:eolMenu];
    for (NSString *e in @[ @"LF", @"CRLF", @"CR" ])
        [eolMenu addItemWithTitle:e action:@selector(changeEOL:) keyEquivalent:@""];
    [viewMenu addItem:eolItem];

    // ---- Encoding
    NSMenuItem *encItem = [[NSMenuItem alloc] init];
    [bar addItem:encItem];
    NSMenu *encMenu = [[NSMenu alloc] initWithTitle:T(@"編碼")];
    [encItem setSubmenu:encMenu];
    for (NSString *e in common_encodings())
    {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:e action:@selector(reopenWithEncoding:) keyEquivalent:@""];
        [it setRepresentedObject:e];
        [encMenu addItem:it];
    }
    [encMenu addItem:[NSMenuItem separatorItem]];
    [encMenu addItemWithTitle:@"Convert to UTF-8" action:@selector(convertToUTF8:) keyEquivalent:@""];
}

- (void)applyTheme:(BOOL)ignored
{
    [self applyChromeColors];
    for (Doc *d in _docs) [self styleEditor:d];
}

- (void)applyChromeColors
{
    Theme *t = [ThemeManager shared].current;
    _dark = t ? t.dark : YES;

    NSColor *bg = t ? [t background] : hex_rgb(0x1E1E1E);
    [_window setBackgroundColor:bg];
    [_window setAppearance:[NSAppearance appearanceNamed:_dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua]];

    NSColor *sbText = _dark ? hex_rgb(0xB0B0B0) : hex_rgb(0x555555);
    [_statusLeft setTextColor:sbText];
    [_statusRight setTextColor:sbText];
    [_statusBar setWantsLayer:YES];
    _statusBar.layer.backgroundColor = (_dark ? hex_rgb(0x252526) : hex_rgb(0xF2F2F2)).CGColor;
    [_tabBar setDark:_dark];
    [_tabBar setNeedsDisplay:YES];
}

- (void)styleEditor:(Doc *)doc
{
    ScintillaView *e = doc.view;
    if (!e) return;

    [e setStringProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:@"Menlo-Regular"];
    [e setGeneralProperty:SCI_STYLESETSIZE parameter:STYLE_DEFAULT value:13];
    [e setStringProperty:SCI_STYLESETFONT parameter:STYLE_LINENUMBER value:@"Menlo-Regular"];
    [e setGeneralProperty:SCI_STYLESETSIZE parameter:STYLE_LINENUMBER value:12];

    [e setGeneralProperty:SCI_SETMARGINTYPEN parameter:0 value:SC_MARGIN_NUMBER];
    [e setGeneralProperty:SCI_SETMARGINWIDTHN parameter:0 value:52];
    [e setGeneralProperty:SCI_SETTABWIDTH value:4];
    [e setGeneralProperty:SCI_SETUSETABS value:0];
    [e setGeneralProperty:SCI_SETCARETLINEVISIBLE value:1];
    [e setGeneralProperty:SCI_SETCARETLINEBACKALPHA value:40];
    [e setGeneralProperty:SCI_SETSELALPHA value:120];
    [e setGeneralProperty:SCI_SETCODEPAGE value:SC_CP_UTF8];
    [e setGeneralProperty:SCI_SETMULTIPLESELECTION value:1];

    // 單字高亮（indicator 30）
    [e message:SCI_INDICSETSTYLE wParam:INDIC_WORD lParam:INDIC_ROUNDBOX];
    [e message:SCI_INDICSETFORE  wParam:INDIC_WORD lParam:(sptr_t)(_dark ? 0x8C7A4B : 0xE0C89A)];   // BGR
    [e message:SCI_INDICSETALPHA wParam:INDIC_WORD lParam:45];
    [e message:SCI_INDICSETOUTLINEALPHA wParam:INDIC_WORD lParam:90];

    // 搜尋結果高亮（indicator 31）
    [e message:SCI_INDICSETSTYLE wParam:INDIC_FIND lParam:INDIC_ROUNDBOX];
    [e message:SCI_INDICSETFORE  wParam:INDIC_FIND lParam:(sptr_t)(_dark ? 0x30A0E0 : 0x009AFF)];   // BGR：橘
    [e message:SCI_INDICSETALPHA wParam:INDIC_FIND lParam:60];
    [e message:SCI_INDICSETOUTLINEALPHA wParam:INDIC_FIND lParam:140];
    [e message:SCI_INDICSETUNDER wParam:INDIC_FIND lParam:1];

    // 書籤與標記
    [e message:SCI_MARKERDEFINE wParam:MARK_BOOKMARK lParam:SC_MARK_BOOKMARK];
    [e message:SCI_MARKERSETFORE wParam:MARK_BOOKMARK lParam:(sptr_t)(_dark ? 0xFFA95A : 0xDB6F2A)];  // BGR
    [e message:SCI_MARKERSETBACK wParam:MARK_BOOKMARK lParam:(sptr_t)(_dark ? 0xFFA95A : 0xDB6F2A)];
    [e message:SCI_MARKERDEFINE wParam:MARK_MATCH lParam:SC_MARK_CIRCLE];
    [e message:SCI_MARKERSETLAYER wParam:MARK_MATCH lParam:SC_LAYER_OVER_TEXT];
    [e message:SCI_MARKERSETBACK wParam:MARK_MATCH lParam:(sptr_t)(_dark ? 0x6FD06F : 0x3FA83F)];
    [e message:SCI_MARKERSETALPHA wParam:MARK_MATCH lParam:255];

    // 書籤與標記共用同一個符號邊界（第 1 欄）
    [e setGeneralProperty:SCI_SETMARGINTYPEN parameter:1 value:SC_MARGIN_SYMBOL];
    [e setGeneralProperty:SCI_SETMARGINWIDTHN parameter:1 value:22];
    [e setGeneralProperty:SCI_SETMARGINMASKN parameter:1
                      value:(sptr_t)((1L << MARK_BOOKMARK) | (1L << MARK_MATCH))];
    [e setGeneralProperty:SCI_SETMARGINWIDTHN parameter:2 value:0];

    [e setGeneralProperty:SCI_SETVIEWWS value:(_showWS ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE)];
    [e setGeneralProperty:SCI_SETVIEWEOL value:(_showEOL ? 1 : 0)];

    [self applyThemeColorsTo:doc];
}

- (void)applyThemeColorsTo:(Doc *)doc
{
    ScintillaView *e = doc.view;
    Theme *t = [ThemeManager shared].current;
    if (!e || !t) return;

    NSDictionary *g = t.globals;
    NSColor *fg = theme_color(g[@"Default Style"][@"fg"], hex_rgb(0xD4D4D4));
    NSColor *bg = theme_color(g[@"Default Style"][@"bg"], hex_rgb(0x1E1E1E));

    [e setColorProperty:SCI_STYLESETFORE parameter:STYLE_DEFAULT value:fg];
    [e setColorProperty:SCI_STYLESETBACK parameter:STYLE_DEFAULT value:bg];
    [e message:SCI_STYLECLEARALL wParam:0 lParam:0];

    NSDictionary *ln = g[@"Line number margin"] ?: @{};
    [e setColorProperty:SCI_STYLESETFORE parameter:STYLE_LINENUMBER value:theme_color(ln[@"fg"], fg)];
    [e setColorProperty:SCI_STYLESETBACK parameter:STYLE_LINENUMBER value:theme_color(ln[@"bg"], bg)];

    // 書籤／標記邊界的底色（預設是白色，會很突兀）
    [e setColorProperty:SCI_SETMARGINBACKN parameter:1 value:bg];

    NSDictionary *caret = g[@"Caret colour"] ?: @{};
    [e setColorProperty:SCI_SETCARETFORE parameter:0 value:theme_color(caret[@"fg"], fg)];

    NSDictionary *cl = g[@"Current line background colour"] ?: @{};
    [e setColorProperty:SCI_SETCARETLINEBACK parameter:0 value:theme_color(cl[@"bg"], bg)];

    NSDictionary *sel = g[@"Selected text colour"] ?: @{};
    [e setColorProperty:SCI_SETSELBACK parameter:1 value:theme_color(sel[@"bg"], fg)];

    NSDictionary *ws = g[@"White space symbol"] ?: @{};
    if (ws[@"fg"]) [e setColorProperty:SCI_SETWHITESPACEFORE parameter:0 value:theme_color(ws[@"fg"], fg)];

    NSDictionary *bm = g[@"Tags match highlighting"] ?: @{};
    if (bm[@"bg"]) [e setColorProperty:SCI_STYLESETBACK parameter:STYLE_BRACELIGHT value:theme_color(bm[@"bg"], bg)];

    // 語言樣式
    NSDictionary *styles = t.lexers[doc.lexerName ?: @"normal"] ?: t.lexers[@"normal"];
    for (NSNumber *sid in styles)
    {
        NSDictionary *st = styles[sid];
        int s = [sid intValue];

        if (st[@"fg"]) [e setColorProperty:SCI_STYLESETFORE parameter:s value:theme_color(st[@"fg"], fg)];
        if (st[@"bg"]) [e setColorProperty:SCI_STYLESETBACK parameter:s value:theme_color(st[@"bg"], bg)];

        int fs = [st[@"style"] intValue];
        [e setGeneralProperty:SCI_STYLESETBOLD parameter:s value:(fs & 1) ? 1 : 0];
        [e setGeneralProperty:SCI_STYLESETITALIC parameter:s value:(fs & 2) ? 1 : 0];
    }
}

- (ScintillaView *)makeEditor
{
    NSRect r = [_editorHost bounds];
    ScintillaView *e = nil;

    if (_viewPool.count)
    {
        e = _viewPool.lastObject;
        [_viewPool removeLastObject];
        [e setFrame:r];
    }
    else
    {
        e = [[ScintillaView alloc] initWithFrame:r];
    }

    [e setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [e setEditable:YES];
    [e setDelegate:nil];
    return e;
}

// 關分頁時不要把 ScintillaView 直接釋放：
// 它在 dealloc 期間會被 AppKit/CoreFoundation 二次存取而爆掉（SIGBUS in ~[ScintillaView dealloc]）。
// 改成回收再利用，整個 session 都不會 dealloc。
- (void)recycleView:(ScintillaView *)v
{
    if (!v) return;

    if ([_window firstResponder] == (id)v) [_window makeFirstResponder:_tabBar];
    [v setDelegate:nil];
    [v removeFromSuperview];

    [v message:SCI_SETUNDOCOLLECTION wParam:0];
    [v message:SCI_CLEARALL];
    [v message:SCI_EMPTYUNDOBUFFER];
    [v message:SCI_SETUNDOCOLLECTION wParam:1];

    if (!_viewPool) _viewPool = [NSMutableArray array];
    if (_viewPool.count < 3) [_viewPool addObject:v];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 分頁

- (void)addDoc:(Doc *)d activate:(BOOL)activate
{
    [_docs addObject:d];
    if (activate) [self selectDoc:d];
    else { [_tabBar setDocs:_docs]; }
}

- (void)selectDoc:(Doc *)doc
{
    NSInteger idx = [_docs indexOfObject:doc];
    if (idx == NSNotFound) return;

    // 記住舊分頁的位置
    if (_active >= 0 && _active < (NSInteger)_docs.count)
    {
        Doc *old = _docs[_active];
        if (old.view)
        {
            old.caret = [old.view getGeneralProperty:SCI_GETCURRENTPOS];
            old.firstVisibleLine = [old.view getGeneralProperty:SCI_GETFIRSTVISIBLELINE];
            old.view.delegate = nil;
        }
    }

    // 換 view
    for (NSView *v in [_editorHost.subviews copy]) [v removeFromSuperview];
    if (!doc.view) doc.view = [self makeEditor];
    doc.view.delegate = self;
    [doc.view setFrame:[_editorHost bounds]];
    [_editorHost addSubview:doc.view];
    [_window makeFirstResponder:doc.view];

    _active = idx;
    [_tabBar setDocs:_docs];
    [_tabBar setSelectedIndex:idx];
    [_tabBar setNeedsDisplay:YES];

    [self styleEditor:doc];
    [self updateStatus];
    [self updateWindowTitle];
    [self saveSession];
}

- (void)tabBar:(TabBarView *)bar didSelect:(NSInteger)index
{
    if (index >= 0 && index < (NSInteger)_docs.count) [self selectDoc:_docs[index]];
}

- (void)tabBar:(TabBarView *)bar didClose:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)_docs.count) return;
    Doc *d = _docs[index];

    if ([d isDirty])
    {
        [self selectDoc:d];
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:[NSString stringWithFormat:T(@"「%@」有未儲存的變更。"), [d title]]];
        [a addButtonWithTitle:T(@"儲存")];
        [a addButtonWithTitle:T(@"不儲存")];
        [a addButtonWithTitle:T(@"取消")];
        NSModalResponse r = [a runModal];
        if (r == NSAlertThirdButtonReturn) return;
        if (r == NSAlertFirstButtonReturn) [self saveDocument:nil];
        if ([d isDirty]) return;   // 使用者取消存檔
    }

    [self recycleView:d.view];
    d.view = nil;
    [_docs removeObjectAtIndex:index];

    if (_docs.count == 0) { [self newDocument:nil]; return; }

    NSInteger next = MIN(index, (NSInteger)_docs.count - 1);
    _active = -1;                    // 強制重設
    [self selectDoc:_docs[next]];
}

- (void)tabBarDidRequestNewTab:(TabBarView *)bar { [self newDocument:nil]; }

- (void)closeActiveTab:(id)sender
{
    if (_active >= 0) [self tabBar:_tabBar didClose:_active];
}

- (void)newDocument:(id)sender
{
    Doc *d = [[Doc alloc] init];
    d.view = [self makeEditor];
    d.encoding = @"UTF-8";
    d.eol = @"LF";
    d.lexerName = @"null";
    [self styleEditor:d];
    [self addDoc:d activate:YES];
    [self updateStatus];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 開檔 / 存檔

- (BOOL)openPath:(NSString *)path
{
    // 已經開過就直接切過去
    for (Doc *d in _docs)
        if (d.path && [d.path isEqualToString:path]) { [self selectDoc:d]; return YES; }

    NSData *raw = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!raw)
    {
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:[NSString stringWithFormat:T(@"無法開啟 %@"), path]];
        [a runModal];
        return NO;
    }

    double t0 = now_ms();
    EncDetection det = detect_encoding(raw);
    double tDetect = now_ms() - t0;

    Doc *d = [[Doc alloc] init];
    d.view = [self makeEditor];
    d.path = path;
    d.encoding = det.name;
    d.hasBOM = det.hasBOM;
    d.eol = detect_eol(raw);

    double t1 = now_ms();
    NSData *utf8 = decode_to_utf8(raw, d.encoding, d.hasBOM);
    double tDecode = now_ms() - t1;

    [d.view setGeneralProperty:SCI_SETUNDOCOLLECTION value:0];
    [d.view message:SCI_CLEARALL];
    [d.view message:SCI_ADDTEXT wParam:(uptr_t)[utf8 length] lParam:(sptr_t)[utf8 bytes]];
    [d.view setGeneralProperty:SCI_SETUNDOCOLLECTION value:1];
    [d.view setGeneralProperty:SCI_EMPTYUNDOBUFFER value:0];
    double tAddEnd = now_ms();
    if (_bench)
        fprintf(stdout, "PHASE detect=%.1f decode=%.1f addtext=%.1f eol_detect=%.1f\n",
                tDetect, tDecode, tAddEnd - t1 - tDecode, 0.0);
    [d.view message:SCI_GOTOPOS wParam:0];          // 開檔後游標回到第 1 行
    [d.view message:SCI_SCROLLCARET];
    _tLoad = now_ms() - t0;                         // 只算「讀檔 → 進 Scintilla」

    d.lexerName = [NSString stringWithUTF8String:lexer_for_path(path)];
    Scintilla::ILexer5 *lexer = CreateLexer(lexer_for_path(path));
    if (lexer)
    {
        [d.view setReferenceProperty:SCI_SETILEXER parameter:0 value:lexer];
        [d.view setReferenceProperty:SCI_SETKEYWORDS parameter:0 value:cpp_keywords];
    }

    [self styleEditor:d];
    _tStyle = now_ms() - t0 - _tLoad;                // 套用主題 + lexer 上色的成本

    [self addDoc:d activate:YES];
    [self updateStatus];
    return YES;
}

- (void)openDocument:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:YES];
    [panel setCanChooseDirectories:NO];
    if ([panel runModal] == NSModalResponseOK)
        for (NSURL *u in [panel URLs]) [self openPath:[u path]];
}

- (BOOL)writeDoc:(Doc *)d toPath:(NSString *)path
{
    ScintillaView *e = d.view;
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    NSMutableData *buf = [NSMutableData dataWithLength:len + 1];
    [e message:SCI_GETTEXT wParam:(uptr_t)len + 1 lParam:(sptr_t)[buf mutableBytes]];
    NSData *utf8 = [NSData dataWithBytes:[buf bytes] length:len];

    utf8 = normalize_eol(utf8, d.eol);

    NSData *out = nil;
    if ([d.encoding isEqualToString:@"UTF-8"])
    {
        out = utf8;
    }
    else
    {
        NSString *s = [[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding];
        NSStringEncoding nsEnc = ns_encoding_for_name(d.encoding);

        if (!nsEnc || !s)
        {
            NSAlert *a = [[NSAlert alloc] init];
            [a setMessageText:[NSString stringWithFormat:T(@"不支援 %@ 編碼"), d.encoding]];
            [a runModal];
            return NO;
        }

        // 先試無損；失敗再問使用者
        out = [s dataUsingEncoding:nsEnc allowLossyConversion:NO];

        if (!out)
        {
            NSAlert *a = [[NSAlert alloc] init];
            [a setMessageText:[NSString stringWithFormat:T(@"有字元無法用 %@ 編碼表示"), d.encoding]];
            [a setInformativeText:T(@"「以 UTF-8 儲存」可完整保留內容；「用 ? 取代」會永久破壞那些字元。")];
            [a addButtonWithTitle:T(@"取消")];
            [a addButtonWithTitle:T(@"以 UTF-8 儲存")];
            [a addButtonWithTitle:T(@"用 ? 取代並儲存")];

            NSModalResponse r = [a runModal];
            if (r == NSAlertFirstButtonReturn)  return NO;          // 取消

            if (r == NSAlertSecondButtonReturn)                     // 改存 UTF-8
            {
                d.encoding = @"UTF-8";
                d.hasBOM = NO;
                out = utf8;
            }
            else                                                    // 破壞性儲存
            {
                out = [s dataUsingEncoding:nsEnc allowLossyConversion:YES];
            }
        }
    }

    NSMutableData *final = [NSMutableData data];
    if (d.hasBOM) [final appendData:bom_for(d.encoding)];
    [final appendData:out];

    NSError *err = nil;
    BOOL ok = [final writeToFile:path options:NSDataWritingAtomic error:&err];
    if (!ok)
    {
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:T(@"儲存失敗")];
        [a setInformativeText:[err localizedDescription] ?: @""];
        [a runModal];
        return NO;
    }

    d.path = path;
    d.metaDirty = NO;
    [e setGeneralProperty:SCI_SETSAVEPOINT value:0];
    [_tabBar setNeedsDisplay:YES];
    [self updateWindowTitle];
    [self updateStatus];
    [self saveSession];
    return YES;
}

- (void)saveDocument:(id)sender
{
    if (_active < 0) return;
    Doc *d = _docs[_active];
    if (!d.path) { [self saveDocumentAs:sender]; return; }
    [self writeDoc:d toPath:d.path];
}

- (void)saveDocumentAs:(id)sender
{
    if (_active < 0) return;
    Doc *d = _docs[_active];
    NSSavePanel *p = [NSSavePanel savePanel];
    if (d.path) [p setNameFieldStringValue:[d.path lastPathComponent]];
    if ([p runModal] == NSModalResponseOK)
        [self writeDoc:d toPath:[[p URL] path]];
}

- (void)reloadDocument:(id)sender
{
    if (_active < 0) return;
    Doc *d = _docs[_active];
    if (!d.path) return;
    NSString *p = d.path;
    [self recycleView:d.view];
    d.view = nil;
    [_docs removeObjectAtIndex:_active];
    _active = -1;
    [self openPath:p];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 編碼 / 換行

- (void)reopenWithEncoding:(NSMenuItem *)item
{
    if (_active < 0) return;
    Doc *d = _docs[_active];
    if (!d.path) return;

    NSString *enc = [item representedObject];
    NSData *raw = [NSData dataWithContentsOfFile:d.path options:NSDataReadingMappedIfSafe error:NULL];
    if (!raw) return;

    BOOL bom = NO;
    const unsigned char *b = (const unsigned char *)[raw bytes];
    if ([raw length] >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF && [enc isEqualToString:@"UTF-8"]) bom = YES;
    if ([raw length] >= 2 && b[0] == 0xFF && b[1] == 0xFE && [enc isEqualToString:@"UTF-16LE"]) bom = YES;
    if ([raw length] >= 2 && b[0] == 0xFE && b[1] == 0xFF && [enc isEqualToString:@"UTF-16BE"]) bom = YES;

    d.encoding = enc;
    d.hasBOM = bom;

    NSData *utf8 = decode_to_utf8(raw, enc, bom);
    [d.view setGeneralProperty:SCI_SETUNDOCOLLECTION value:0];
    [d.view message:SCI_CLEARALL];
    [d.view message:SCI_ADDTEXT wParam:(uptr_t)[utf8 length] lParam:(sptr_t)[utf8 bytes]];
    [d.view setGeneralProperty:SCI_SETUNDOCOLLECTION value:1];
    [d.view setGeneralProperty:SCI_EMPTYUNDOBUFFER value:0];
    [d.view setGeneralProperty:SCI_SETSAVEPOINT value:0];

    [self styleEditor:d];
    [self updateStatus];
    [self saveSession];
}

- (void)convertToUTF8:(id)sender
{
    if (_active < 0) return;
    Doc *d = _docs[_active];
    d.encoding = @"UTF-8";
    d.hasBOM = NO;
    d.metaDirty = YES;   // 標記為已修改，提醒存檔
    [self updateStatus];
    [_tabBar setNeedsDisplay:YES];
}

- (void)changeEOL:(NSMenuItem *)item
{
    if (_active < 0) return;
    Doc *d = _docs[_active];
    d.eol = [item title];
    d.metaDirty = YES;
    [self updateStatus];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 編輯動作

- (ScintillaView *)editor { return (_active >= 0 && _active < (NSInteger)_docs.count) ? _docs[_active].view : nil; }

- (void)undo:(id)sender   { [[self editor] message:SCI_UNDO]; }
- (void)redo:(id)sender   { [[self editor] message:SCI_REDO]; }
- (void)cut:(id)sender    { [[self editor] message:SCI_CUT]; }
- (void)copy:(id)sender   { [[self editor] message:SCI_COPY]; }
- (void)paste:(id)sender  { [[self editor] message:SCI_PASTE]; }
- (void)selectAll:(id)sender { [[self editor] message:SCI_SELECTALL]; }

- (void)showFind:(id)sender
{
    ScintillaView *e = [self editor];
    if (!e) return;

    NSAlert *a = [[NSAlert alloc] init];
    [a setMessageText:@"Find"];
    [a addButtonWithTitle:@"Next"];
    [a addButtonWithTitle:@"Cancel"];
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    [a setAccessoryView:f];
    if ([a runModal] != NSAlertFirstButtonReturn) return;

    NSString *needle = [f stringValue];
    if (!needle.length) return;

    long start = [e getGeneralProperty:SCI_GETCURRENTPOS];
    [e message:SCI_SETTARGETSTART wParam:(uptr_t)start];
    [e message:SCI_SETTARGETEND wParam:(uptr_t)[e getGeneralProperty:SCI_GETLENGTH]];
    long pos = [e message:SCI_SEARCHINTARGET wParam:(uptr_t)[needle length]
                                  lParam:(sptr_t)[needle UTF8String]];
    if (pos >= 0)
    {
        [e message:SCI_SETSEL wParam:(uptr_t)pos lParam:(sptr_t)(pos + [needle length])];
        [e message:SCI_SCROLLCARET];
    }
    else NSBeep();
}

- (void)goToLine:(id)sender
{
    ScintillaView *e = [self editor];
    if (!e) return;
    NSAlert *a = [[NSAlert alloc] init];
    [a setMessageText:@"Go to Line"];
    [a addButtonWithTitle:@"Go"];
    [a addButtonWithTitle:@"Cancel"];
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 160, 24)];
    [a setAccessoryView:f];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    long line = [[f stringValue] integerValue];
    long total = [e getGeneralProperty:SCI_GETLINECOUNT];
    if (line < 1) line = 1;
    if (line > total) line = total;
    [e message:SCI_GOTOLINE wParam:(uptr_t)(line - 1)];
    [e message:SCI_SCROLLCARET];
}

- (void)toggleDark:(id)sender { [self applyTheme:!_dark]; }

- (void)toggleLineNumbers:(id)sender
{
    ScintillaView *e = [self editor];
    long w = [e getGeneralProperty:SCI_GETMARGINWIDTHN parameter:0];
    [e setGeneralProperty:SCI_SETMARGINWIDTHN parameter:0 value:(w ? 0 : 52)];
}

- (void)toggleWrap:(id)sender
{
    ScintillaView *e = [self editor];
    long m = [e getGeneralProperty:SCI_GETWRAPMODE];
    [e setGeneralProperty:SCI_SETWRAPMODE value:(m == SC_WRAP_NONE ? SC_WRAP_WORD : SC_WRAP_NONE)];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 狀態列

- (void)updateWindowTitle
{
    if (_active < 0) { [_window setTitle:@"sPad++"]; return; }
    Doc *d = _docs[_active];
    [_window setTitle:[NSString stringWithFormat:@"%@ — sPad++", [d title]]];
}

- (void)updateStatus
{
    ScintillaView *e = [self editor];
    if (!e) { [_statusLeft setStringValue:T(@"就緒")]; [_statusRight setStringValue:@""]; return; }
    Doc *d = _docs[_active];

    long pos  = [e getGeneralProperty:SCI_GETCURRENTPOS];
    long line = [e getGeneralProperty:SCI_LINEFROMPOSITION parameter:pos];
    long col  = [e getGeneralProperty:SCI_GETCOLUMN parameter:pos];
    long selLen = [e message:SCI_GETSELECTIONEND] - [e message:SCI_GETSELECTIONSTART];
    long lines = [e getGeneralProperty:SCI_GETLINECOUNT];
    long bytes = [e getGeneralProperty:SCI_GETLENGTH];

    NSString *enc = d.encoding;
    if (d.hasBOM) enc = [enc stringByAppendingString:@" BOM"];

    NSString *left = [NSString stringWithFormat:T(@"%@   ·   %ld 行   ·   %@"),
                      [d title], lines, human_bytes(bytes)];
    NSString *right = [NSString stringWithFormat:T(@"%@   ·   %@   ·   行 %ld，欄 %ld   ·   %ld 字元選取   ·   載入 %.0f ms"),
                       enc, d.eol, line + 1, col + 1, selLen, _tLoad];

    // 只在內容真的變了才動 UI（捲動時這裡每幀都會被呼叫）
    if (![left isEqualToString:_lastStatusLeft])
    {
        _lastStatusLeft = [left copy];
        [_statusLeft setStringValue:left];
    }
    if (![right isEqualToString:_lastStatusRight])
    {
        _lastStatusRight = [right copy];
        [_statusRight setStringValue:right];
    }
}

- (void)notification:(SCNotification *)scn
{
    if (scn->nmhdr.code == SCN_UPDATEUI)
    {
        // SC_UPDATE_V_SCROLL 只代表「畫面捲動」，游標與內容都沒變：
        // 這時候不需要更新狀態列、括號配對或單字高亮。
        if (scn->updated != 0 && (scn->updated & ~SC_UPDATE_V_SCROLL) == 0) return;

        [self updateStatus];
        [self updateBraceHighlight];
        [self updateWordHighlight];
    }
    else if (scn->nmhdr.code == SCN_CHARADDED)
    {
        [self handleCharAdded:scn->ch];
    }
    else if (scn->nmhdr.code == SCN_SAVEPOINTLEFT || scn->nmhdr.code == SCN_SAVEPOINTREACHED)
    {
        [_tabBar setNeedsDisplay:YES];
    }
}

//--------------------------------------------------------------------------------------------------
#pragma mark Session

- (NSString *)sessionPath
{
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    dir = [dir stringByAppendingPathComponent:@"sPad++"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"session.json"];
}

- (void)saveSession
{
    if (!_docs) return;

    NSMutableArray *arr = [NSMutableArray array];
    for (Doc *d in _docs)
    {
        if (!d.path) continue;                 // 未命名的分頁不存
        long caret = (d == (_active >= 0 ? _docs[_active] : nil))
                   ? [d.view getGeneralProperty:SCI_GETCURRENTPOS] : d.caret;
        long fl = (d == (_active >= 0 ? _docs[_active] : nil))
                   ? [d.view getGeneralProperty:SCI_GETFIRSTVISIBLELINE] : d.firstVisibleLine;

        [arr addObject:@{ @"path": d.path,
                          @"caret": @(caret),
                          @"line": @(fl),
                          @"enc": d.encoding,
                          @"bom": @(d.hasBOM),
                          @"eol": d.eol }];
    }
    NSDictionary *root = @{ @"active": @(_active), @"docs": arr, @"dark": @(_dark) };
    NSData *json = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:NULL];
    [json writeToFile:[self sessionPath] atomically:YES];
}

- (void)restoreSession
{
    NSData *json = [NSData dataWithContentsOfFile:[self sessionPath]];
    if (!json) return;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) return;

    if ([root[@"dark"] boolValue]) { _dark = YES; [self applyTheme:YES]; }

    NSArray *arr = root[@"docs"];
    for (NSDictionary *item in arr)
    {
        NSString *p = item[@"path"];
        if (!p || ![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;

        [self openPath:p];
        Doc *d = _docs.lastObject;
        if (!d) continue;

        long caret = [item[@"caret"] longValue];
        long firstLine = [item[@"line"] longValue];
        if (caret >= 0 && caret <= [d.view getGeneralProperty:SCI_GETLENGTH])
            [d.view message:SCI_GOTOPOS wParam:(uptr_t)caret];
        [d.view message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)firstLine];
        [d.view message:SCI_SETSAVEPOINT];
    }

    NSInteger act = [root[@"active"] integerValue];
    if (act >= 0 && act < (NSInteger)_docs.count) [self selectDoc:_docs[act]];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 基準測試 / 截圖

- (void)runBenchmark:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:NO];
    if ([panel runModal] != NSModalResponseOK) return;
    [self openPath:[[panel URL] path]];
    [self benchActive:[[panel URL] path]];
}

- (void)benchActive:(NSString *)path
{
    ScintillaView *e = [self editor];
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    long lines = [e getGeneralProperty:SCI_GETLINECOUNT];

    double t = now_ms();
    [e message:SCI_GOTOLINE wParam:(uptr_t)(lines - 1)];
    [e message:SCI_SCROLLCARET];
    double gotoEnd = now_ms() - t;

    const char *absent = "ZZZ_THIS_STRING_DOES_NOT_EXIST_9F3A";
    t = now_ms();
    [e message:SCI_SETTARGETSTART wParam:0];
    [e message:SCI_SETTARGETEND wParam:(uptr_t)len];
    long absentPos = [e message:SCI_SEARCHINTARGET wParam:strlen(absent) lParam:(sptr_t)absent];
    double fullScan = now_ms() - t;

    fprintf(stdout, "BENCH file=%s bytes=%ld lines=%ld load_ms=%.1f style_ms=%.1f goto_end_ms=%.1f fullscan_ms=%.1f absent=%ld enc=%s eol=%s\n",
            [path UTF8String], len, lines, _tLoad, _tStyle, gotoEnd, fullScan, absentPos,
            [_docs[_active].encoding UTF8String], [_docs[_active].eol UTF8String]);
    fflush(stdout);
}

- (void)doBenchAndQuit
{
    if (_active >= 0 && _docs[_active].path) [self benchActive:_docs[_active].path];

    if (_saveTest && _active >= 0)
    {
        Doc *d = _docs[_active];
        NSString *before = d.encoding;
        BOOL ok = [self writeDoc:d toPath:d.path];
        NSData *after = [NSData dataWithContentsOfFile:d.path];
        fprintf(stdout, "SAVETEST path=%s enc=%s ok=%d size=%lu\n",
                [d.path UTF8String], [before UTF8String], (int)ok, (unsigned long)after.length);
        fflush(stdout);
    }

    // 中文輸入路徑（NSTextInputClient 在內層 SCIContentView 上）
    {
        ScintillaView *e = [self editor];
        id content = [e content];
        BOOL conforms = [content conformsToProtocol:@protocol(NSTextInputClient)];
        BOOL inserted = NO, committed = NO;
        @try {
            [e setString:@""];
            [content insertText:@"中文測試" replacementRange:NSMakeRange(NSNotFound, 0)];
            inserted = [[e string] isEqualToString:@"中文測試"];
            [content setMarkedText:@"zhong" selectedRange:NSMakeRange(5, 0)
                  replacementRange:NSMakeRange(NSNotFound, 0)];
            [content insertText:@"中" replacementRange:NSMakeRange(NSNotFound, 0)];
            committed = [[e string] rangeOfString:@"中"].location != NSNotFound;
        } @catch (NSException *ex) {
            fprintf(stdout, "IME exception=%s\n", [[ex reason] UTF8String]);
        }
        fprintf(stdout, "IME conforms=%d directInsert=%d commit=%d\n",
                (int)conforms, (int)inserted, (int)committed);
        fflush(stdout);
    }

    [self saveSession];
    [NSApp terminate:nil];
}


//--------------------------------------------------------------------------------------------------
#pragma mark UI 自動驗收

static BOOL saveWindowPNG(NSWindow *w, NSString *path)
{
    [w makeKeyAndOrderFront:nil];
    NSView *cv = [[w contentView] superview];
    [cv layoutSubtreeIfNeeded];
    [w displayIfNeeded];
    [[w contentView] display];
    NSBitmapImageRep *rep = [cv bitmapImageRepForCachingDisplayInRect:[cv bounds]];
    [cv cacheDisplayInRect:[cv bounds] toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}


static void dumpEditorUTF8(ScintillaView *e, NSString *path)
{
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    char *b = (char *)malloc(len + 1);
    [e message:SCI_GETTEXT wParam:(uptr_t)len + 1 lParam:(sptr_t)b];
    [[NSData dataWithBytes:b length:len] writeToFile:path atomically:YES];
    free(b);
}


static void hc_log(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [s stringByAppendingString:@"\n"];
    fprintf(stdout, "%s", [line UTF8String]);
    fflush(stdout);
    FILE *f = fopen("/tmp/hidecheck.log", "a");
    if (f) { fputs([line UTF8String], f); fclose(f); }
}





- (void)doCloseCheck
{
    fprintf(stdout, "CLOSE docs=%lu\n", (unsigned long)_docs.count); fflush(stdout);

    // 依序關閉每一個分頁
    while (_docs.count > 1)
    {
        fprintf(stdout, "CLOSE closing index 1 of %lu\n", (unsigned long)_docs.count); fflush(stdout);
        [self tabBar:_tabBar didClose:1];
        fprintf(stdout, "CLOSE ok, docs=%lu\n", (unsigned long)_docs.count); fflush(stdout);
    }

    // 再開幾個再關掉，測重複使用
    for (int i = 0; i < 60; i++)
    {
        @autoreleasepool
        {
            [self newDocument:nil];
            [self tabBar:_tabBar didClose:(NSInteger)_docs.count - 1];
        }
    }
    fprintf(stdout, "CLOSE churn ok, docs=%lu\n", (unsigned long)_docs.count); fflush(stdout);

    [NSApp terminate:nil];
}

- (void)doScrollStress
{
    [_window makeKeyAndOrderFront:nil];
    _stressTicks = 0;
    _stressTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                    target:self
                                                  selector:@selector(stressTick)
                                                  userInfo:nil
                                                   repeats:YES];
}

- (void)stressTick
{
    ScintillaView *e = [self editor];
    [e message:SCI_LINESCROLL wParam:0 lParam:((_stressTicks / 60) % 2 ? -3 : 3)];
    _stressTicks++;
    if (_stressTicks > 60 * 8)
    {
        [_stressTimer invalidate];
        fprintf(stdout, "STRESS done %d ticks\n", _stressTicks);
        fflush(stdout);
        [NSApp terminate:nil];
    }
}

- (void)doScrollBench
{
    [_window makeKeyAndOrderFront:nil];
    [self performSelector:@selector(runScrollBench) withObject:nil afterDelay:0.6];
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x < y) ? -1 : (x > y);
}

- (void)runScrollBench
{
    ScintillaView *e = [self editor];
    NSView *root = [[_window contentView] superview];
    if (!e) { fprintf(stdout, "SCROLL no editor\n"); [NSApp terminate:nil]; return; }

    const int N = 300;
    double t[N];
    long lines = [e getGeneralProperty:SCI_GETLINECOUNT];

    for (int i = 0; i < N; i++)
    {
        double t0 = now_ms();
        [e message:SCI_LINESCROLL wParam:0 lParam:(i < N / 2 ? 4 : -4)];
        [root display];
        t[i] = now_ms() - t0;
    }

    double sum = 0, max = 0;
    int slow = 0;
    for (int i = 0; i < N; i++) { sum += t[i]; if (t[i] > max) max = t[i]; if (t[i] > 16.7) slow++; }
    double sorted[N];
    memcpy(sorted, t, sizeof(t));
    qsort(sorted, N, sizeof(double), cmp_double);

    fprintf(stdout,
            "SCROLL lines=%ld steps=%d avg=%.2fms p50=%.2f p95=%.2f max=%.2f slow(>16.7ms)=%d/%d\n",
            lines, N, sum / N, sorted[N / 2], sorted[(int)(N * 0.95)], max, slow, N);
    fflush(stdout);
    [NSApp terminate:nil];
}

- (void)doEditCheck
{
    ScintillaView *e = [self editor];

    // 1) 矩形（欄位）選取模式
    [e setGeneralProperty:SCI_SETSELECTIONMODE value:SC_SEL_RECTANGLE];
    fprintf(stdout, "CHECK selectionMode=%ld (want %d)\n",
            (long)[e getGeneralProperty:SCI_GETSELECTIONMODE], (int)SC_SEL_RECTANGLE);
    [e setGeneralProperty:SCI_SETSELECTIONMODE value:SC_SEL_STREAM];

    // 2) 縮放
    [e message:SCI_ZOOMIN];
    [e message:SCI_ZOOMIN];
    fprintf(stdout, "CHECK zoom=%ld\n", (long)[e getGeneralProperty:SCI_GETZOOM]);
    [e setGeneralProperty:SCI_SETZOOM value:0];

    // 3) 多選：選一個字，再加下一個相同
    [e message:SCI_GOTOPOS wParam:0];
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    long wordStart = -1, wordEnd = -1;
    for (long i = 0; i < MIN(len, 4000); i++)
    {
        int c = (int)[e message:SCI_GETCHARAT wParam:(uptr_t)i];
        if (isalnum(c)) { if (wordStart < 0) wordStart = i; }
        else if (wordStart >= 0) { wordEnd = i; break; }
    }
    if (wordStart >= 0 && wordEnd > wordStart)
    {
        [e message:SCI_SETSEL wParam:(uptr_t)wordStart lParam:(sptr_t)wordEnd];
        char wb[64] = {0};
        [e message:SCI_GETSELTEXT wParam:(uptr_t)sizeof(wb) lParam:(sptr_t)wb];
        [e message:SCI_SETTARGETSTART wParam:0];
        [e message:SCI_SETTARGETEND wParam:(uptr_t)[e getGeneralProperty:SCI_GETLENGTH]];
        [e message:SCI_MULTIPLESELECTADDNEXT];
        fprintf(stdout, "CHECK word=[%s] selections=%ld\n",
                wb, (long)[e getGeneralProperty:SCI_GETSELECTIONS]);
        [e message:SCI_SETSELECTION wParam:0 lParam:0];
    }
    else fprintf(stdout, "CHECK word=NOTFOUND\n");

    // 4) 自動完成（先直接測訊息，再測我們的單字收集）
    {
        NSString *probe = @"alpha beta gamma delta";
        [e message:SCI_AUTOCSHOW wParam:0 lParam:(sptr_t)[probe UTF8String]];
        fprintf(stdout, "CHECK autocDirect=%ld\n", (long)[e message:SCI_AUTOCACTIVE]);
        [e message:SCI_AUTOCCANCEL];

        [self showAutoComplete:nil];
        fprintf(stdout, "CHECK autocFromDoc=%ld\n", (long)[e message:SCI_AUTOCACTIVE]);
        [e message:SCI_AUTOCCANCEL];
    }

    // 5) 空白字元顯示
    [self toggleWhitespace:nil];
    fprintf(stdout, "CHECK viewWS=%ld\n", (long)[e getGeneralProperty:SCI_GETVIEWWS]);
    [self toggleWhitespace:nil];

    // 6) 自動縮排（直接測邏輯）
    [e message:SCI_DOCUMENTEND];
    [e message:SCI_NEWLINE];
    [e message:SCI_ADDTEXT wParam:9 lParam:(sptr_t)"int x = {"];
    long before = [e getGeneralProperty:SCI_GETLINECOUNT];
    [e message:SCI_NEWLINE];
    [self autoIndentNewline];
    long line = before;   // 新產生的那一行（0-based）
    long ind = [e getGeneralProperty:SCI_GETLINEINDENTATION parameter:line];
    fprintf(stdout, "CHECK autoIndent=%ld (want 4)\n", ind);

    // 7) 書籤
    [e message:SCI_GOTOLINE wParam:10];
    [self toggleBookmark:nil];
    [e message:SCI_GOTOLINE wParam:0];
    [self nextBookmark:nil];
    fprintf(stdout, "CHECK bookmarkLine=%ld (want 10)\n",
            (long)[e getGeneralProperty:SCI_LINEFROMPOSITION
                              parameter:[e getGeneralProperty:SCI_GETCURRENTPOS]]);
    [self toggleBookmark:nil];

    // 8) 全部標記
    [self findPanel];
    [_findPanel.findField setStringValue:@"Scintilla"];
    [self markAllMatches:nil];
    long markedLines = 0;
    long totalLines = [e getGeneralProperty:SCI_GETLINECOUNT];
    for (long ln = 0; ln < totalLines; ln++)
        if ([e message:SCI_MARKERGET wParam:(uptr_t)ln] & (1L << MARK_MATCH)) markedLines++;
    fprintf(stdout, "CHECK markedLines=%ld\n", markedLines);

    // 截一張有書籤與標記的圖
    [e message:SCI_GOTOLINE wParam:30]; [self toggleBookmark:nil];
    [e message:SCI_GOTOLINE wParam:60]; [self toggleBookmark:nil];
    [e message:SCI_GOTOLINE wParam:90]; [self toggleBookmark:nil];
    [e message:SCI_GOTOLINE wParam:70];
    [e message:SCI_SCROLLCARET];
    fprintf(stdout, "CHECK markAt74=%ld markAt75=%ld markAt83=%ld\n",
            (long)([e message:SCI_MARKERGET wParam:74] & (1L << MARK_MATCH)) ? 1 : 0,
            (long)([e message:SCI_MARKERGET wParam:75] & (1L << MARK_MATCH)) ? 1 : 0,
            (long)([e message:SCI_MARKERGET wParam:83] & (1L << MARK_MATCH)) ? 1 : 0);
    saveWindowPNG(_window, @"/tmp/spad_marks.png");

    [self clearMarks:nil];

    // 9) 背景搜尋（先確保面板存在）
    [self findPanel];
    [_findPanel setMode:FPModeFiles];
    [_findPanel.findField setStringValue:@"Notepad"];
    [_findPanel.dirField setStringValue:@"../third_party"];
    [_findPanel.filterField setStringValue:@"*.cpp;*.h;*.cxx"];

    // 主執行緒心跳：量「最大延遲」，若 UI 被卡住會出現一個很大的 gap
    static dispatch_source_t hb;
    static int ticks = 0;
    static double lastTick = 0, maxGap = 0;
    lastTick = now_ms();
    hb = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(hb, DISPATCH_TIME_NOW, 20ull * NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(hb, ^{
        double t = now_ms();
        double gap = t - lastTick;
        if (gap > maxGap) maxGap = gap;
        lastTick = t;
        ticks++;
    });
    dispatch_resume(hb);
    [self fpRunFindInFiles];
    fprintf(stdout, "FIF started (should return immediately)\n");
    fflush(stdout);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fprintf(stdout, "FIF heartbeat ticks=%d maxGap=%.0fms (20ms 週期；maxGap 越大代表 UI 被卡住)\n",
                ticks, maxGap);
        fprintf(stdout, "FIF running=%d rows=%lu status=%s\n",
                (int)self->_fifRunning,
                (unsigned long)[[self->_findPanel resultItems] count],
                [[self->_findPanel.statusLabel stringValue] UTF8String]);
        fflush(stdout);
        [NSApp terminate:nil];
    });
}

- (void)doHideCheck
{
    hc_log(@"HIDE start windows=%lu frontmost=%d",
           (unsigned long)[[NSApp windows] count], (int)[NSApp isActive]);

    if (getenv("HIDE_WITH_PANEL") || _hidePanel)
    {
        [self showFindPanel:FPModeFind];
        [_findPanel.findField setStringValue:@"int"];
        [self fpRecount];
        [_findPanel makeKeyAndOrderFront:nil];
        hc_log(@"HIDE panel open key=%d", (int)[_findPanel isKeyWindow]);
    }

    if (getenv("CLOSE_TEST"))
    {
        fprintf(stdout, "CLOSE releasedWhenClosed=%d\n", (int)[_window isReleasedWhenClosed]);
        fflush(stdout);
        [_window performClose:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fprintf(stdout, "CLOSE survived, windows=%lu\n", (unsigned long)[[NSApp windows] count]);
            fflush(stdout);
            [NSApp terminate:nil];
        });
        return;
    }

    // 走真正的選單快速鍵路徑
    NSEvent *ev = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                   location:NSZeroPoint
                              modifierFlags:NSEventModifierFlagCommand
                                  timestamp:[[NSProcessInfo processInfo] systemUptime]
                               windowNumber:_window.windowNumber
                                    context:nil
                                 characters:@"h"
                charactersIgnoringModifiers:@"h"
                                  isARepeat:NO
                                    keyCode:4];
    [NSApp sendEvent:ev];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        hc_log(@"HIDE survived: hidden=%d windows=%lu",
                (int)[NSApp isHidden], (unsigned long)[[NSApp windows] count]);
        [NSApp unhide:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            hc_log(@"UNHIDE ok: hidden=%d key=%d", (int)[NSApp isHidden], (int)[_window isKeyWindow]);

        [NSApp hide:nil];
        hc_log(@"HIDE again hidden=%d visible=%d", (int)[NSApp isHidden], (int)[_window isVisible]);
        [self applicationShouldHandleReopen:NSApp hasVisibleWindows:NO];
        hc_log(@"REOPEN visible=%d hidden=%d", (int)[_window isVisible], (int)[NSApp isHidden]);
            [NSApp terminate:nil];
        });
    });
}

- (void)doUICheck
{
    // ---- 取代：在副本上做
    NSString *src = @"../testdata/rt/big5.txt";
    NSString *dst = @"../testdata/rt/uicheck.txt";
    [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:NULL];
    [self openPath:dst];

    dumpEditorUTF8([self editor], @"/tmp/stage1_open.txt");
    saveWindowPNG(_window, @"/tmp/spad_main.png");
    [self showFindPanel:FPModeReplace];
    {
        NSRect wf = _window.frame, pf = _findPanel.frame;
        NSRect vf = [[NSScreen mainScreen] visibleFrame];
        fprintf(stdout, "GEOM screen=%.0fx%.0f win=(%.0f,%.0f %.0fx%.0f) panel=(%.0f,%.0f %.0fx%.0f)\n",
                vf.size.width, vf.size.height, wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
                pf.origin.x, pf.origin.y, pf.size.width, pf.size.height);
        fprintf(stdout, "GEOM panelCenterDX=%.0f panelTopGap=%.0f\n",
                NSMidX(pf) - NSMidX(wf), NSMaxY(wf) - NSMaxY(pf));
        fflush(stdout);
    }
    [_findPanel.findField setStringValue:@"測試"];
    [_findPanel.replaceField setStringValue:@"TEST"];
    [self fpRecount];

    fprintf(stdout, "FIND %s\n", [[_findPanel.statusLabel stringValue] UTF8String] ?: "(nil)");
    {
        ScintillaView *ed = [self editor];
        long len = [ed getGeneralProperty:SCI_GETLENGTH];
        long hit = -1;
        for (long i = 0; i + 2 <= len; i++)
            if ([ed message:SCI_INDICATORVALUEAT wParam:INDIC_FIND lParam:(sptr_t)i] != 0) { hit = i; break; }
        long total = 0;
        for (long i = 0; i < len; i++)
            if ([ed message:SCI_INDICATORVALUEAT wParam:INDIC_FIND lParam:(sptr_t)i] != 0) total++;
        fprintf(stdout, "HIGHLIGHT first=%ld chars=%ld\n", hit, total);
    }
    fflush(stdout);

    saveWindowPNG(_findPanel, @"/tmp/spad_find.png");
    saveWindowPNG(_window, @"/tmp/spad_highlight.png");

    [self fpReplaceAll];
    fprintf(stdout, "REPLACEALL %s\n", [[_findPanel.statusLabel stringValue] UTF8String] ?: "(nil)");
    fflush(stdout);
    dumpEditorUTF8([self editor], @"/tmp/stage2_replaced.txt");
    [self saveDocument:nil];

    // ---- 檔案中尋找
    [_findPanel setMode:FPModeFiles];
    [_findPanel.dirField setStringValue:@"../testdata"];
    [_findPanel.filterField setStringValue:@"*.txt"];
    [_findPanel.findField setStringValue:@"第二行"];
    [self fpRunFindInFiles];
    fprintf(stdout, "FIF %s rows=%lu\n",
            [[_findPanel.statusLabel stringValue] UTF8String] ?: "(nil)",
            (unsigned long)[_findPanel resultItems].count);
    fflush(stdout);

    saveWindowPNG(_findPanel, @"/tmp/spad_files.png");

    [NSApp terminate:nil];
}
- (void)doSnapshot
{
    NSView *cv = [[_window contentView] superview];
    [cv layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [cv bitmapImageRepForCachingDisplayInRect:[cv bounds]];
    [cv cacheDisplayInRect:[cv bounds] toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    BOOL ok = [png writeToFile:_snapshotPath atomically:YES];
    fprintf(stdout, "SNAPSHOT path=%s ok=%d bytes=%lu\n",
            [_snapshotPath UTF8String], (int)ok, (unsigned long)[png length]);
    fprintf(stdout, "DOCS count=%lu active=%ld\n", (unsigned long)_docs.count, (long)_active);
    for (Doc *d in _docs)
        fprintf(stdout, "  tab=%s enc=%s%s eol=%s dirty=%d\n",
                [[d title] UTF8String], [d.encoding UTF8String], d.hasBOM ? "+BOM" : "",
                [d.eol UTF8String], (int)[d isDirty]);
    fflush(stdout);
    [self saveSession];
    [NSApp terminate:nil];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 搜尋引擎

static long sc_find(ScintillaView *e, NSString *needle, FindOptions o, long from, long to, long *outLen)
{
    if (!needle.length || !e || from < 0 || to < 0 || from > to) return -1;

    Sci_TextToFindFull tt;
    memset(&tt, 0, sizeof(tt));
    tt.chrg.cpMin = (Sci_PositionCR)from;
    tt.chrg.cpMax = (Sci_PositionCR)to;
    tt.lpstrText = (char *)[needle UTF8String];

    int flags = 0;
    if (o.matchCase) flags |= SCFIND_MATCHCASE;
    if (o.wholeWord) flags |= SCFIND_WHOLEWORD;
    if (o.regex)     flags |= SCFIND_REGEXP | SCFIND_CXX11REGEX;

    long pos = (long)[e message:SCI_FINDTEXTFULL wParam:(uptr_t)flags lParam:(sptr_t)&tt];
    if (pos >= 0 && outLen)
        *outLen = (long)tt.chrgText.cpMax - (long)tt.chrgText.cpMin;
    return pos;
}

static BOOL looks_binary(NSData *d)
{
    const unsigned char *b = (const unsigned char *)[d bytes];
    NSUInteger n = MIN([d length], (NSUInteger)8192);
    for (NSUInteger i = 0; i < n; i++) if (b[i] == 0) return YES;
    return NO;
}

static NSString *decode_to_string(NSData *data)
{
    EncDetection d = detect_encoding(data);
    NSUInteger skip = 0;
    if (d.hasBOM)
    {
        if ([d.name isEqualToString:@"UTF-8"]) skip = 3;
        else if ([d.name isEqualToString:@"UTF-16LE"] || [d.name isEqualToString:@"UTF-16BE"]) skip = 2;
    }
    NSData *payload = skip ? [data subdataWithRange:NSMakeRange(skip, [data length] - skip)] : data;

    NSStringEncoding enc = ns_encoding_for_name(d.name);
    NSString *s = enc ? [[NSString alloc] initWithData:payload encoding:enc] : nil;
    if (!s) s = [[NSString alloc] initWithData:payload encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

static BOOL filter_matches(NSString *name, NSString *filter)
{
    if (!filter.length) return YES;
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@";, "];
    for (NSString *pat in [filter componentsSeparatedByCharactersInSet:sep])
    {
        if (!pat.length) continue;
        if (fnmatch([pat UTF8String], [name UTF8String], FNM_CASEFOLD) == 0) return YES;
    }
    return NO;
}

static BOOL is_word_char(unichar c)
{
    return c == '_' || [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c > 127;
}

//--------------------------------------------------------------------------------------------------
#pragma mark 尋找 / 取代（UI 側）

- (FindPanel *)findPanel
{
    if (!_findPanel) _findPanel = [[FindPanel alloc] initWithHost:self];
    return _findPanel;
}

- (FindOptions)fpOptions
{
    FindOptions o = { NO, NO, NO, YES };
    if (!_findPanel) return o;
    o.matchCase = [_findPanel.caseCheck  state] == NSControlStateValueOn;
    o.wholeWord = [_findPanel.wordCheck  state] == NSControlStateValueOn;
    o.regex     = [_findPanel.regexCheck state] == NSControlStateValueOn;
    o.wrap      = [_findPanel.wrapCheck  state] == NSControlStateValueOn;
    return o;
}

- (void)menuFind:(id)s        { [self showFindPanel:FPModeFind]; }
- (void)menuReplace:(id)s     { [self showFindPanel:FPModeReplace]; }
- (void)menuFindInFiles:(id)s { [self showFindPanel:FPModeFiles]; }
- (void)menuFindNext:(id)s    { [self fpFindNext]; }
- (void)menuFindPrev:(id)s    { [self fpFindPrev]; }

- (void)showFindPanel:(FPMode)mode
{
    FindPanel *p = [self findPanel];

    // 若編輯器有選取，帶入尋找欄（Notepad++ 行為）
    ScintillaView *e = [self editor];
    if (e)
    {
        long ss = [e message:SCI_GETSELECTIONSTART];
        long se = [e message:SCI_GETSELECTIONEND];
        if (se > ss && se - ss < 200)
        {
            char buf[512] = {0};
            [e message:SCI_GETSELTEXT wParam:(uptr_t)sizeof(buf) lParam:(sptr_t)buf];
            NSString *sel = [NSString stringWithUTF8String:buf];
            if (sel.length && [sel rangeOfString:@"\n"].location == NSNotFound)
                [p.findField setStringValue:sel];
        }
    }

    [p showMode:mode inWindow:_window];
    [[p findField] becomeFirstResponder];
    [self fpOptionsChanged];
}

- (void)fpPanelClosed
{
    if (_fifRunning) [self fpCancelFindInFiles];
    [self clearFindHighlights];
    if (_findPanel) [_findPanel setStatus:@"" error:NO];
    [_window makeFirstResponder:[self editor]];
}

- (void)fpOptionsChanged
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fpRecount) object:nil];
    [self performSelector:@selector(fpRecount) withObject:nil afterDelay:0.12];
}

- (void)clearFindHighlights
{
    ScintillaView *e = [self editor];
    if (!e) return;
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    [e message:SCI_SETINDICATORCURRENT wParam:INDIC_FIND];
    [e message:SCI_INDICATORCLEARRANGE wParam:0 lParam:(sptr_t)len];
}

- (NSInteger)indexOfFirstMatchAtOrAfter:(long)pos
{
    for (NSUInteger i = 0; i < _findRanges.count; i++)
    {
        NSRange r = [_findRanges[i] rangeValue];
        if ((long)r.location >= pos) return (NSInteger)i;
    }
    return (NSInteger)_findRanges.count;
}

- (void)fpRecount
{
    if (!_findPanel) return;
    ScintillaView *e = [self editor];
    if (!e) return;

    if (!_findRanges) _findRanges = [NSMutableArray array];
    [_findRanges removeAllObjects];
    [self clearFindHighlights];

    NSString *needle = [_findPanel.findField stringValue];
    if (!needle.length) { [_findPanel setStatus:@"" error:NO]; return; }

    FindOptions o = [self fpOptions];
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    long pos = 0, l = 0;
    BOOL truncated = NO, invalid = NO;
    double t0 = now_ms();

    [e message:SCI_SETINDICATORCURRENT wParam:INDIC_FIND];

    while (pos <= len)
    {
        long p = sc_find(e, needle, o, pos, len, &l);
        if (p < 0) break;
        if (l == 0 && p == pos && pos >= len) break;

        [_findRanges addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)p, (NSUInteger)l)]];
        [e message:SCI_INDICATORFILLRANGE wParam:(uptr_t)p lParam:(sptr_t)l];

        pos = p + (l > 0 ? l : 1);
        if (_findRanges.count >= 4000 || now_ms() - t0 > 250) { truncated = YES; break; }
    }

    if (_findRanges.count == 0)
    {
        if (o.regex && sc_find(e, needle, o, 0, 0, NULL) < 0 && needle.length)
            invalid = NO;   // 交由 macOS regex 錯誤提示（略）
        [_findPanel setStatus:(o.regex ? T(@"沒有符合的結果（或表示式無效）") : T(@"沒有符合的結果")) error:YES];
        return;
    }

    long cur = [e getGeneralProperty:SCI_GETCURRENTPOS];
    NSInteger idx = [self indexOfFirstMatchAtOrAfter:cur];
    NSString *txt = [NSString stringWithFormat:T(@"%ld 筆符合%@　·　目前第 %ld 筆"),
                     (long)_findRanges.count,
                     truncated ? T(@"（已達上限，僅顯示前 4000 筆）") : @"",
                     (long)(idx >= (NSInteger)_findRanges.count ? 1 : idx + 1)];
    [_findPanel setStatus:txt error:NO];
    (void)invalid;
}

- (void)fpFindNext { [self fpFindForward:YES]; }
- (void)fpFindPrev { [self fpFindForward:NO]; }

- (void)fpFindForward:(BOOL)forward
{
    if (!_findPanel) return;
    ScintillaView *e = [self editor];
    if (!e) return;

    NSString *needle = [_findPanel.findField stringValue];
    if (!needle.length) { NSBeep(); return; }
    [_findPanel addHistory:needle];

    FindOptions o = [self fpOptions];
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    long pos = -1, l = 0;

    if (forward)
    {
        long from = [e message:SCI_GETSELECTIONEND];
        pos = sc_find(e, needle, o, from, len, &l);
        if (pos < 0 && o.wrap) pos = sc_find(e, needle, o, 0, len, &l);
    }
    else
    {
        long upto = [e message:SCI_GETSELECTIONSTART];
        long start = 0, best = -1, bestLen = 0;
        while (start <= upto)
        {
            long p = sc_find(e, needle, o, start, upto, &l);
            if (p < 0) break;
            best = p; bestLen = l;
            start = p + (l > 0 ? l : 1);
        }
        if (best < 0 && o.wrap)
        {
            start = 0;
            while (start <= len)
            {
                long p = sc_find(e, needle, o, start, len, &l);
                if (p < 0) break;
                best = p; bestLen = l;
                start = p + (l > 0 ? l : 1);
            }
        }
        pos = best; l = bestLen;
    }

    if (pos < 0) { NSBeep(); [_findPanel setStatus:T(@"找不到") error:YES]; return; }

    [e message:SCI_SETSEL wParam:(uptr_t)pos lParam:(sptr_t)(pos + l)];
    [e message:SCI_SCROLLCARET];
    [_window makeFirstResponder:e];

    // 更新「第 k 筆」提示
    if (_findRanges.count)
    {
        NSInteger idx = [self indexOfFirstMatchAtOrAfter:pos];
        [_findPanel setStatus:[NSString stringWithFormat:T(@"%ld 筆符合　·　目前第 %ld 筆"),
                               (long)_findRanges.count,
                               (long)(idx >= (NSInteger)_findRanges.count ? _findRanges.count : idx + 1)]
                        error:NO];
    }
}

- (void)fpReplaceOne
{
    if (!_findPanel) return;
    ScintillaView *e = [self editor];
    if (!e) return;

    NSString *needle = [_findPanel.findField stringValue];
    NSString *rep = [_findPanel.replaceField stringValue];
    if (!needle.length) { NSBeep(); return; }

    FindOptions o = [self fpOptions];
    long ss = [e message:SCI_GETSELECTIONSTART];
    long se = [e message:SCI_GETSELECTIONEND];

    BOOL selMatches = NO;
    if (se > ss)
    {
        long l = 0;
        long p = sc_find(e, needle, o, ss, se, &l);
        selMatches = (p == ss && l == (se - ss));
    }

    if (!selMatches) { [self fpFindForward:YES]; return; }

    [e message:SCI_BEGINUNDOACTION];
    [e message:SCI_SETTARGETSTART wParam:(uptr_t)ss];
    [e message:SCI_SETTARGETEND wParam:(uptr_t)se];
    if (o.regex)
        [e message:SCI_REPLACETARGETRE wParam:(uptr_t)-1 lParam:(sptr_t)[rep UTF8String]];
    else
        [e message:SCI_REPLACETARGET wParam:(uptr_t)[rep lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                                   lParam:(sptr_t)[rep UTF8String]];
    [e message:SCI_ENDUNDOACTION];

    [_findPanel addHistory:needle];
    [self fpFindForward:YES];
    [self fpOptionsChanged];
}

- (void)fpReplaceAll
{
    if (!_findPanel) return;
    ScintillaView *e = [self editor];
    if (!e) return;

    NSString *needle = [_findPanel.findField stringValue];
    NSString *rep = [_findPanel.replaceField stringValue];
    if (!needle.length) { NSBeep(); return; }

    [_findPanel addHistory:needle];

    FindOptions o = [self fpOptions];
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    long pos = 0, l = 0, count = 0;
    double t0 = now_ms();

    [e message:SCI_BEGINUNDOACTION];
    while (pos <= len)
    {
        long p = sc_find(e, needle, o, pos, len, &l);
        if (p < 0) break;

        [e message:SCI_SETTARGETSTART wParam:(uptr_t)p];
        [e message:SCI_SETTARGETEND wParam:(uptr_t)(p + l)];
        if (o.regex)
            [e message:SCI_REPLACETARGETRE wParam:(uptr_t)-1 lParam:(sptr_t)[rep UTF8String]];
        else
            [e message:SCI_REPLACETARGET wParam:(uptr_t)[rep lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                                       lParam:(sptr_t)[rep UTF8String]];

        pos = [e getGeneralProperty:SCI_GETTARGETEND];
        if (l == 0) pos = p + 1;
        len = [e getGeneralProperty:SCI_GETLENGTH];

        count++;
        if (count > 200000 || now_ms() - t0 > 15000) break;
    }
    [e message:SCI_ENDUNDOACTION];

    [_findPanel setStatus:[NSString stringWithFormat:T(@"已取代 %ld 筆（%.0f ms）"), count, now_ms() - t0]
                    error:(count == 0)];
    [self fpOptionsChanged];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 檔案中尋找

- (void)fpCancelFindInFiles
{
    _fifGen++;
    if (_fifJob) [(FIFJob *)_fifJob setCancelled:YES];
    _fifJob = nil;
    _fifRunning = NO;
    if (_findPanel)
    {
        [_findPanel.goBtn setTitle:T(@"開始搜尋")];
        [_findPanel setStatus:T(@"已停止") error:NO];
    }
}

- (void)fpRunFindInFiles
{
    if (!_findPanel) return;
    if (_fifRunning) { [self fpCancelFindInFiles]; return; }

    NSString *needle = [_findPanel.findField stringValue];
    NSString *dir    = [_findPanel.dirField stringValue];
    NSString *filter = [_findPanel.filterField stringValue];

    if (!needle.length) { [_findPanel setStatus:T(@"請先輸入要尋找的文字") error:YES]; return; }
    if (!dir.length) dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    dir = [dir stringByExpandingTildeInPath];

    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir)
    {
        [_findPanel setStatus:T(@"資料夾不存在") error:YES];
        return;
    }

    FindOptions o = [self fpOptions];
    NSRegularExpression *re = nil;
    if (o.regex)
    {
        NSError *err = nil;
        re = [NSRegularExpression regularExpressionWithPattern:needle
                                                       options:(o.matchCase ? 0 : NSRegularExpressionCaseInsensitive)
                                                         error:&err];
        if (!re)
        {
            [_findPanel setStatus:[NSString stringWithFormat:T(@"正規表示式錯誤：%@"),
                                   [err localizedDescription] ?: @""] error:YES];
            return;
        }
    }

    [_findPanel addHistory:needle];

    FIFJob *job = [[FIFJob alloc] init];
    _fifJob = job;
    NSUInteger gen = ++_fifGen;
    _fifRunning = YES;
    [_findPanel.goBtn setTitle:T(@"停止")];
    [_findPanel setResultItems:@[]];
    [_findPanel setStatus:T(@"搜尋中…") error:NO];

    NSString *needleC = [needle copy];
    NSString *dirC    = [dir copy];
    NSString *filterC = [filter copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *items = [NSMutableArray array];
        NSUInteger scanned = 0, lastFlush = 0;
        double t0 = now_ms();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:dirC];
        BOOL truncated = NO;

        for (NSString *rel in en)
        {
            if (job.cancelled) break;
            if (now_ms() - t0 > 120000) { truncated = YES; break; }

            NSString *full = [dirC stringByAppendingPathComponent:rel];

            BOOL itemDir = NO;
            [fm fileExistsAtPath:full isDirectory:&itemDir];
            if (itemDir)
            {
                NSString *n = [rel lastPathComponent];
                if ([n isEqualToString:@".git"] || [n isEqualToString:@"node_modules"] ||
                    [n isEqualToString:@"build"] || [n isEqualToString:@".build"] ||
                    [n isEqualToString:@"DerivedData"])
                    [en skipDescendants];
                continue;
            }

            if (!filter_matches([rel lastPathComponent], filterC)) continue;

            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
            if ([attrs fileSize] > 16 * 1024 * 1024) continue;

            NSData *data = [NSData dataWithContentsOfFile:full];
            if (!data || looks_binary(data)) continue;

            scanned++;
            NSString *content = decode_to_string(data);
            NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];

            for (NSUInteger i = 0; i < lines.count; i++)
            {
                NSString *line = lines[i];
                if (!line.length || line.length > 4000) continue;

                BOOL hit = NO;
                if (re)
                {
                    NSRange r = [re rangeOfFirstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
                    hit = (r.location != NSNotFound);
                }
                else
                {
                    NSStringCompareOptions co = o.matchCase ? 0 : NSCaseInsensitiveSearch;
                    NSRange r = [line rangeOfString:needleC options:co];
                    if (r.location != NSNotFound)
                    {
                        hit = YES;
                        if (o.wholeWord)
                        {
                            NSUInteger b = r.location, e2 = r.location + r.length;
                            if (b > 0 && is_word_char([line characterAtIndex:b - 1])) hit = NO;
                            if (e2 < line.length && is_word_char([line characterAtIndex:e2])) hit = NO;
                        }
                    }
                }

                if (hit)
                {
                    NSString *trimmed = line;
                    if (trimmed.length > 160)
                        trimmed = [[trimmed substringToIndex:160] stringByAppendingString:@"…"];
                    [items addObject:@{ @"path": full,
                                        @"rel": [rel copy],
                                        @"line": @(i + 1),
                                        @"text": [trimmed stringByTrimmingCharactersInSet:
                                                  [NSCharacterSet whitespaceCharacterSet]] }];
                    if (items.count >= 5000) { truncated = YES; break; }
                }
            }

            if (items.count >= 5000) break;

            // 每 40 筆回報一次進度（複本在背景執行緒做，避免競態）
            if (items.count - lastFlush >= 40)
            {
                lastFlush = items.count;
                NSArray *snap = [items copy];
                NSUInteger sc = scanned;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (gen != self->_fifGen) return;
                    [self->_findPanel setResultItems:snap];
                    [self->_findPanel setStatus:[NSString stringWithFormat:T(@"搜尋中…  已掃描 %lu 檔，%lu 筆"),
                                                 (unsigned long)sc, (unsigned long)snap.count] error:NO];
                });
            }
        }

        NSArray *final = [items copy];
        NSUInteger files = scanned;
        double elapsed = now_ms() - t0;
        BOOL cut = truncated;
        BOOL wasCancelled = job.cancelled;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_fifGen) return;
            self->_fifRunning = NO;
            self->_fifJob = nil;
            [self->_findPanel.goBtn setTitle:T(@"開始搜尋")];
            [self->_findPanel setResultItems:final];
            [self->_findPanel setStatus:[NSString stringWithFormat:T(@"%@ 在 %lu 個檔案中找到 %lu 筆（%.0f ms）%@"),
                                        wasCancelled ? T(@"已停止 —") : @"",
                                        (unsigned long)files, (unsigned long)final.count, elapsed,
                                        cut ? T(@"，已達上限") : @""]
                                   error:(final.count == 0)];
        });
    });
}

- (void)fpReveal:(NSString *)path line:(NSInteger)line
{
    if (!path.length) return;
    [self openPath:path];

    ScintillaView *e = [self editor];
    if (!e) return;

    [e message:SCI_GOTOLINE wParam:(uptr_t)(MAX(0, line - 1))];
    [e message:SCI_SCROLLCARET];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:e];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 編輯手感

- (void)updateBraceHighlight
{
    ScintillaView *e = [self editor];
    if (!e) return;

    long len = [e getGeneralProperty:SCI_GETLENGTH];
    long pos = [e getGeneralProperty:SCI_GETCURRENTPOS];

    int ch = 0;
    if (pos >= 0 && pos < len) ch = (int)[e message:SCI_GETCHARAT wParam:(uptr_t)pos];

    if (ch == '(' || ch == ')' || ch == '[' || ch == ']' || ch == '{' || ch == '}')
    {
        long m = [e message:SCI_BRACEMATCH wParam:(uptr_t)pos lParam:0];
        if (m >= 0) [e message:SCI_BRACEHIGHLIGHT wParam:(uptr_t)pos lParam:(sptr_t)m];
        else        [e message:SCI_BRACEBADLIGHT wParam:(uptr_t)pos];
    }
    else
    {
        [e message:SCI_BRACEHIGHLIGHT wParam:(uptr_t)-1 lParam:(sptr_t)-1];
    }
}

- (void)updateWordHighlight
{
    ScintillaView *e = [self editor];
    if (!e) return;

    long ss = [e message:SCI_GETSELECTIONSTART];
    long se = [e message:SCI_GETSELECTIONEND];
    NSString *word = nil;

    if (se - ss >= 2 && se - ss <= 64 && [e getGeneralProperty:SCI_GETSELECTIONS] == 1)
    {
        char buf[256] = {0};
        [e message:SCI_GETSELTEXT wParam:(uptr_t)sizeof(buf) lParam:(sptr_t)buf];
        NSString *sel = [NSString stringWithUTF8String:buf];
        if (sel.length >= 2 &&
            [sel rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound)
            word = sel;
    }

    if (word == _lastWord || [word isEqualToString:_lastWord ?: @""]) return;   // 沒變就不重畫
    _lastWord = [word copy];

    long len = [e getGeneralProperty:SCI_GETLENGTH];
    [e message:SCI_SETINDICATORCURRENT wParam:INDIC_WORD];
    [e message:SCI_INDICATORCLEARRANGE wParam:0 lParam:(sptr_t)len];
    if (!word.length) return;

    // 全檔同字高亮（上限 1000 處）
    FindOptions o = { YES, NO, NO, NO };
    long pos = 0, l = 0;
    NSInteger n = 0;
    double t0 = now_ms();
    while (pos <= len && n < 1000)
    {
        long p = sc_find(e, word, o, pos, len, &l);
        if (p < 0) break;
        [e message:SCI_INDICATORFILLRANGE wParam:(uptr_t)p lParam:(sptr_t)l];
        pos = p + (l > 0 ? l : 1);
        n++;
        if (now_ms() - t0 > 60) break;
    }
}

- (void)handleCharAdded:(int)ch
{
    if (ch == '\n')      [self autoIndentNewline];
    else if (ch == '}')  [self autoDedentCloseBrace];
}

- (void)autoIndentNewline
{
    ScintillaView *e = [self editor];
    long pos  = [e getGeneralProperty:SCI_GETCURRENTPOS];
    long line = [e getGeneralProperty:SCI_LINEFROMPOSITION parameter:pos];
    if (line < 1) return;

    long prev = line - 1;
    long indent  = [e getGeneralProperty:SCI_GETLINEINDENTATION parameter:prev];
    long prevEnd = [e getGeneralProperty:SCI_GETLINEENDPOSITION parameter:prev];

    int last = 0;
    if (prevEnd > 0) last = (int)[e message:SCI_GETCHARAT wParam:(uptr_t)(prevEnd - 1)];

    long extra = (last == '{' || last == '(' || last == '[') ? 4 : 0;
    if (indent + extra > 0)
        [e setGeneralProperty:SCI_SETLINEINDENTATION parameter:line value:indent + extra];
}

- (void)autoDedentCloseBrace
{
    ScintillaView *e = [self editor];
    long pos = [e getGeneralProperty:SCI_GETCURRENTPOS];
    long line = [e getGeneralProperty:SCI_LINEFROMPOSITION parameter:pos];
    long lineStart = [e getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];

    for (long p = lineStart; p < pos; p++)
    {
        int c = (int)[e message:SCI_GETCHARAT wParam:(uptr_t)p];
        if (c != ' ' && c != '\t' && c != '}') return;   // 前面不是空白就不動
    }

    long indent = [e getGeneralProperty:SCI_GETLINEINDENTATION parameter:line];
    if (indent >= 4)
        [e setGeneralProperty:SCI_SETLINEINDENTATION parameter:line value:indent - 4];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 多游標 / 縮放 / 空白 / 自動完成

- (void)selectNextOccurrence:(id)sender
{
    ScintillaView *e = [self editor];
    // MULTIPLESELECTADDNEXT 只在 target range 內找，預設是 0..0 → 一定要先設整份
    [e message:SCI_SETTARGETSTART wParam:0];
    [e message:SCI_SETTARGETEND wParam:(uptr_t)[e getGeneralProperty:SCI_GETLENGTH]];
    [e message:SCI_MULTIPLESELECTADDNEXT];
    [_window makeFirstResponder:e];
    [self updateStatus];
}

- (void)selectAllOccurrences:(id)sender
{
    ScintillaView *e = [self editor];
    [e message:SCI_SETTARGETSTART wParam:0];
    [e message:SCI_SETTARGETEND wParam:(uptr_t)[e getGeneralProperty:SCI_GETLENGTH]];
    [e message:SCI_MULTIPLESELECTADDEACH];
    [_window makeFirstResponder:e];
    [self updateStatus];
}

- (void)zoomIn:(id)sender    { [[self editor] message:SCI_ZOOMIN]; }
- (void)zoomOut:(id)sender   { [[self editor] message:SCI_ZOOMOUT]; }
- (void)zoomReset:(id)sender { [[self editor] setGeneralProperty:SCI_SETZOOM value:0]; }

- (void)toggleWhitespace:(id)sender
{
    _showWS = !_showWS;
    for (Doc *d in _docs)
        [d.view setGeneralProperty:SCI_SETVIEWWS value:(_showWS ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE)];
}

- (void)toggleEOL:(id)sender
{
    _showEOL = !_showEOL;
    for (Doc *d in _docs)
        [d.view setGeneralProperty:SCI_SETVIEWEOL value:(_showEOL ? 1 : 0)];
}

- (void)showAutoComplete:(id)sender
{
    ScintillaView *e = [self editor];
    if (!e) return;

    long len = [e getGeneralProperty:SCI_GETLENGTH];
    long cap = MIN(len, 300000);
    if (cap <= 0) return;

    char *buf = (char *)malloc(cap + 1);
    [e message:SCI_GETTEXT wParam:(uptr_t)cap + 1 lParam:(sptr_t)buf];
    buf[cap] = 0;

    NSMutableSet *set = [NSMutableSet set];
    char token[128];
    int tl = 0;
    for (long i = 0; i < cap && set.count < 2000; i++)
    {
        unsigned char c = (unsigned char)buf[i];
        BOOL isWord = (isalnum(c) || c == '_' || c >= 0x80);
        if (isWord)
        {
            if (tl < 127) token[tl++] = (char)c;
        }
        else
        {
            if (tl >= 3) { token[tl] = 0; [set addObject:[NSString stringWithUTF8String:token]]; }
            tl = 0;
        }
    }
    if (tl >= 3) { token[tl] = 0; [set addObject:[NSString stringWithUTF8String:token]]; }
    free(buf);

    if (set.count == 0) { NSBeep(); return; }

    NSArray *sorted = [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSString *list = [sorted componentsJoinedByString:@" "];

    // 先把焦點還給編輯器，否則等一下的 makeFirstResponder 會把清單關掉
    [_window makeFirstResponder:e];
    [e message:SCI_AUTOCSHOW wParam:0 lParam:(sptr_t)[list UTF8String]];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 主題切換

- (void)rebuildThemeMenu
{
    if (!_themeMenu) return;
    [_themeMenu removeAllItems];

    Theme *cur = [ThemeManager shared].current;
    for (Theme *t in [ThemeManager shared].themes)
    {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:t.displayName
                                                    action:@selector(selectTheme:)
                                             keyEquivalent:@""];
        [it setRepresentedObject:t.identifier];
        [it setState:(t == cur) ? NSControlStateValueOn : NSControlStateValueOff];
        [_themeMenu addItem:it];
    }
    [_themeMenu addItem:[NSMenuItem separatorItem]];
    [_themeMenu addItemWithTitle:T(@"重新載入主題") action:@selector(reloadThemes:) keyEquivalent:@""];
    [_themeMenu addItemWithTitle:T(@"開啟主題資料夾…") action:@selector(openThemeFolder:) keyEquivalent:@""];
}

- (void)selectTheme:(NSMenuItem *)item
{
    if (![[ThemeManager shared] selectTheme:[item representedObject]]) return;
    [self rebuildThemeMenu];
    [self applyTheme:YES];
}

- (void)reloadThemes:(id)sender
{
    [[ThemeManager shared] reload];
    [self rebuildThemeMenu];
    [self applyTheme:YES];
    [self flashStatus:[NSString stringWithFormat:T(@"已載入 %lu 個主題"),
                       (unsigned long)[ThemeManager shared].themes.count]];
}

- (void)openThemeFolder:(id)sender
{
    NSString *dir = [[ThemeManager shared] userThemeDirectory];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 書籤與標記

- (void)flashStatus:(NSString *)msg
{
    [_statusLeft setStringValue:msg];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateStatus) object:nil];
    [self performSelector:@selector(updateStatus) withObject:nil afterDelay:1.6];
}

- (long)lineOfMarker:(int)marker from:(long)startLine backwards:(BOOL)backwards
{
    ScintillaView *e = [self editor];
    long mask = (1L << marker);
    long total = [e getGeneralProperty:SCI_GETLINECOUNT];

    if (!backwards)
    {
        long line = [e message:SCI_MARKERNEXT wParam:(uptr_t)startLine lParam:(sptr_t)mask];
        if (line < 0) line = [e message:SCI_MARKERNEXT wParam:0 lParam:(sptr_t)mask];   // 繞回開頭
        return line;
    }

    long best = -1, l = 0, pos = 0;
    while (pos < startLine)
    {
        l = [e message:SCI_MARKERNEXT wParam:(uptr_t)pos lParam:(sptr_t)mask];
        if (l < 0 || l >= startLine) break;
        best = l;
        pos = l + 1;
    }
    if (best >= 0) return best;

    // 從後面繞回
    pos = startLine;
    while (pos <= total)
    {
        l = [e message:SCI_MARKERNEXT wParam:(uptr_t)pos lParam:(sptr_t)mask];
        if (l < 0) break;
        best = l;
        pos = l + 1;
    }
    return best;
}

- (void)toggleBookmark:(id)sender
{
    ScintillaView *e = [self editor];
    if (!e) return;

    long pos  = [e getGeneralProperty:SCI_GETCURRENTPOS];
    long line = [e getGeneralProperty:SCI_LINEFROMPOSITION parameter:pos];
    long mask = [e message:SCI_MARKERGET wParam:(uptr_t)line];

    if (mask & (1L << MARK_BOOKMARK))
        [e message:SCI_MARKERDELETE wParam:(uptr_t)line lParam:MARK_BOOKMARK];
    else
        [e message:SCI_MARKERADD wParam:(uptr_t)line lParam:MARK_BOOKMARK];

    [self flashStatus:((mask & (1L << MARK_BOOKMARK)) ? T(@"已移除書籤") : T(@"已加入書籤"))];
}

- (void)gotoMarker:(int)marker backwards:(BOOL)backwards
{
    ScintillaView *e = [self editor];
    if (!e) return;

    long cur  = [e getGeneralProperty:SCI_LINEFROMPOSITION
                            parameter:[e getGeneralProperty:SCI_GETCURRENTPOS]];
    long from = backwards ? cur : (cur + 1);
    long line = [self lineOfMarker:marker from:from backwards:backwards];

    if (line < 0) { NSBeep(); [self flashStatus:T(@"沒有書籤")]; return; }

    [e message:SCI_GOTOLINE wParam:(uptr_t)line];
    [e message:SCI_SCROLLCARET];
    [_window makeFirstResponder:e];
}

- (void)nextBookmark:(id)sender { [self gotoMarker:MARK_BOOKMARK backwards:NO]; }
- (void)prevBookmark:(id)sender { [self gotoMarker:MARK_BOOKMARK backwards:YES]; }

- (void)markAllMatches:(id)sender
{
    ScintillaView *e = [self editor];
    if (!e) return;

    if (!_findPanel) { NSBeep(); return; }
    NSString *needle = [_findPanel.findField stringValue];
    if (!needle.length) { NSBeep(); [self flashStatus:T(@"請先在尋找面板輸入文字")]; return; }

    FindOptions o = [self fpOptions];
    long len = [e getGeneralProperty:SCI_GETLENGTH];
    long pos = 0, l = 0, lines = 0, lastLine = -1;
    double t0 = now_ms();

    [e message:SCI_MARKERDELETEALL wParam:MARK_MATCH];
    [e message:SCI_BEGINUNDOACTION];

    while (pos <= len)
    {
        long p = sc_find(e, needle, o, pos, len, &l);
        if (p < 0) break;

        long line = [e getGeneralProperty:SCI_LINEFROMPOSITION parameter:p];
        if (line != lastLine)
        {
            [e message:SCI_MARKERADD wParam:(uptr_t)line lParam:MARK_MATCH];
            lastLine = line;
            lines++;
        }

        pos = p + (l > 0 ? l : 1);
        if (lines >= 5000 || now_ms() - t0 > 500) break;
    }

    [e message:SCI_ENDUNDOACTION];
    [self flashStatus:[NSString stringWithFormat:T(@"已標記 %ld 行"), lines]];
    [_findPanel setStatus:[NSString stringWithFormat:T(@"已標記 %ld 行"), lines] error:(lines == 0)];
}

- (void)clearMarks:(id)sender
{
    ScintillaView *e = [self editor];
    if (!e) return;
    [e message:SCI_MARKERDELETEALL wParam:MARK_MATCH];
    [self flashStatus:T(@"已清除標記")];
}

//--------------------------------------------------------------------------------------------------
#pragma mark 分頁移動

- (void)tabBar:(TabBarView *)bar didMoveFrom:(NSInteger)from to:(NSInteger)to
{
    if (from == to) return;
    if (from < 0 || from >= (NSInteger)_docs.count) return;
    if (to < 0 || to >= (NSInteger)_docs.count) return;

    Doc *d = _docs[from];
    [_docs removeObjectAtIndex:from];
    [_docs insertObject:d atIndex:to];

    _active = [_docs indexOfObject:d];
    [bar setDocs:_docs];
    [bar setSelectedIndex:_active];
    [bar ensureVisibleIndex:_active];
    [bar setNeedsDisplay:YES];
    [self saveSession];
}

@end

//--------------------------------------------------------------------------------------------------

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
