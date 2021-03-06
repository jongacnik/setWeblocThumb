/*

setWeblocThumb
--------------
Sets custom icons for .webloc files that display a thumbnail of the
web page that the URL contained by the file points to.

Copyright (c) 2009-2013 Ali Rantakari (http://hasseg.org)

--------------

Licensed under the Apache License, Version 2.0 (the "License"); you may
not use this file except in compliance with the License. You may obtain
a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

*/

#include <libgen.h>
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import "MBBase64.h"
#import "imgBase64.m"
#import "HGCLIUtils.h"
#import "launchAgentGen.h"


#define GETURL_AS_FORMAT_STR    @"tell the application \"Finder\" to return location of (POSIX file \"%@\" as file)"
#define WEBVIEW_FRAME_RECT      NSMakeRect(0, 0, 700, 700)
#define WEBVIEW_SCREENSHOT_SIZE NSMakeSize(1280, 1024)
#define THUMB_DRAWING_RECT      NSMakeRect(95, 160, 320, 320)
#define FAVICON_DRAWING_RECT    NSMakeRect(390, 412, 100, 100)


const int VERSION_MAJOR = 1;
const int VERSION_MINOR = 0;
const int VERSION_BUILD = 0;


NSImage *baseIconImage = nil;
BOOL arg_verbose = NO;
WebPreferences *webViewPrefs = nil;
double screenshotDelaySec = 0.0;


NSString* versionNumberStr()
{
    return [NSString stringWithFormat:@"%d.%d.%d", VERSION_MAJOR, VERSION_MINOR, VERSION_BUILD];
}


BOOL fileHasCustomIcon(NSString *filePath)
{
    FSRef fsRef;
    if (FSPathMakeRef((const UInt8 *)[filePath fileSystemRepresentation], &fsRef, NULL) != noErr)
        return NO;
    
    FSCatalogInfo fsCatalogInfo;
    if (FSGetCatalogInfo(&fsRef, kFSCatInfoFinderInfo, &fsCatalogInfo, NULL, NULL, NULL) == noErr)
    {
        FileInfo *fileInfo = (FileInfo*)(&fsCatalogInfo.finderInfo);
        UInt16 infoFlags = fileInfo->finderFlags;
        return ((infoFlags & kHasCustomIcon) != 0);
    }
    
    return NO;
}


NSString * getURLOfWeblocFile(NSString *path)
{
    // try reading .webloc as plist
    NSString *ret = nil;
    NSDictionary *weblocDict = [NSDictionary dictionaryWithContentsOfFile:path];
    ret = [weblocDict objectForKey:@"URL"];
    if (ret != nil)
        return ret;
    
    // if not a plist, try asking Finder (slower)
    NSDictionary *appleScriptError;
    NSString *escapedPath = [path stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *asSource = [NSString stringWithFormat:GETURL_AS_FORMAT_STR, escapedPath];
    NSAppleScript *getURLAppleScript = [[NSAppleScript alloc] initWithSource:asSource];
    NSAppleEventDescriptor *ed = [getURLAppleScript executeAndReturnError:&appleScriptError];
    [getURLAppleScript release];
    return [ed stringValue];
}



void VerbosePrintf(NSString *aStr, ...)
{
    if (!arg_verbose)
        return;
    va_list argList;
    va_start(argList, aStr);
    NSString *str = [
        [[NSString alloc]
            initWithFormat:aStr
            locale:[[NSUserDefaults standardUserDefaults] dictionaryRepresentation]
            arguments:argList
            ] autorelease
        ];
    va_end(argList);
    
    [str writeToFile:@"/dev/stdout" atomically:NO encoding:outputStrEncoding error:NULL];
}







// a WeblocIconifier is responsible for loading the web page
// that a .webloc file's URL points to, creating an icon with
// the thumbnail of that web page and assigning it to the
// .webloc file
@interface WeblocIconifier:NSObject
{
    WebView *webView;
    NSString *weblocFilePath;
    NSString *weblocURL;
    NSImage *favicon;
    BOOL doneIconizing;
    BOOL doneLoadingPage;
    BOOL loadFavicon;
    AliasHandle fileAliasHandle;
}

@property(retain) WebView *webView;
@property(copy) NSString *weblocFilePath;
@property(copy) NSString *weblocURL;
@property(copy) NSImage *favicon;

- (BOOL) doneIconizing;
- (void) startLoadingWithFavicon:(BOOL)aLoadFavicon;
- (void) setSelfAsDone;
- (void) doneLoading;
- (void) drawAndSetIcon;
- (BOOL) saveAliasOfPath:(NSString *)path;
- (NSString *) pathFromSavedAlias;

@end

@implementation WeblocIconifier

@synthesize webView;
@synthesize weblocFilePath;
@synthesize weblocURL;
@synthesize favicon;

- (id) init
{
    if (!(self = [super init]))
        return nil;
    
    doneIconizing = NO;
    doneLoadingPage = NO;
    loadFavicon = NO;
    fileAliasHandle = NULL;
    
    return self;
}

- (void) dealloc
{
    self.webView = nil;
    self.weblocFilePath = nil;
    self.weblocURL = nil;
    self.favicon = nil;
    fileAliasHandle = NULL;
    [super dealloc];
}


- (void) startLoadingWithFavicon:(BOOL)aLoadFavicon
{
    VerbosePrintf(@"start: %@\n", self.weblocFilePath);
    
    NSAssert((self.weblocFilePath != nil), @"self.weblocFilePath is nil");
    
    [self saveAliasOfPath:self.weblocFilePath];
    
    loadFavicon = aLoadFavicon;
    
    // create webView and start loading the page
    if (self.webView == nil)
    {
        self.webView = [[WebView alloc] init];
        [self.webView setFrame:WEBVIEW_FRAME_RECT];
        [[[self.webView mainFrame] frameView] setAllowsScrolling:NO];
        [self.webView setDrawsBackground:YES];
        [self.webView setFrameLoadDelegate:self];
        [self.webView setResourceLoadDelegate:self];
        [self.webView setPreferences:webViewPrefs];
    }
    self.weblocURL = getURLOfWeblocFile(weblocFilePath);
    VerbosePrintf(@"  url: %@\n", self.weblocURL);
    if (self.weblocURL == nil)
    {
        PrintfErr(@" -> cannot get URL for: %@\n", self.weblocFilePath);
        doneIconizing = YES;
    }
    [self.webView setMainFrameURL:self.weblocURL];
}

- (BOOL) doneIconizing
{
    return doneIconizing;
}

- (void) setSelfAsDone
{
    doneIconizing = YES;
    VerbosePrintf(@" -> done: %@\n", self.weblocFilePath);
}



- (void) doneLoading
{
    if (!doneLoadingPage)
        return;
    
    [self drawAndSetIcon];
}


- (NSImage *) generatedIconImage
{
    // get screenshot from webView
    NSBitmapImageRep *webViewImageRep = [webView bitmapImageRepForCachingDisplayInRect:[webView frame]];
    [webView cacheDisplayInRect:[webView frame] toBitmapImageRep:webViewImageRep];
    NSImage *webViewImage = [[NSImage alloc] initWithSize:WEBVIEW_SCREENSHOT_SIZE];
    [webViewImage addRepresentation:webViewImageRep];
    
    // draw screenshot on top of base image
    NSImage *newIconImage = [[baseIconImage copy] autorelease];
    [newIconImage lockFocus];
    [webViewImage
        drawInRect:THUMB_DRAWING_RECT
        fromRect:NSZeroRect
        operation:NSCompositeCopy
        fraction:1.0
        ];
    [newIconImage unlockFocus];
    [webViewImage release];
    
    // draw favicon on top of new icon
    if (self.favicon != nil)
    {
        [newIconImage lockFocus];
        [favicon
            drawInRect:FAVICON_DRAWING_RECT
            fromRect:NSZeroRect
            operation:NSCompositeSourceOver
            fraction:1.0
            ];
        [newIconImage unlockFocus];
    }
    
    return newIconImage;
}


- (NSString *) currentWeblocFilePath
{
    // resolve the file's alias handle (in case the
    // file has been moved within the same filesystem)
    NSString *resolvedWeblocFilePath = [self pathFromSavedAlias];
    if (resolvedWeblocFilePath == nil)
        resolvedWeblocFilePath = self.weblocFilePath;
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:resolvedWeblocFilePath])
    {
        VerbosePrintf(@" -> can't find file even through its alias handle (moved to another volume?).\n");
        VerbosePrintf(@"    searching in containing folder for .weblocs with the same URL.\n");
        
        // in desperation, go through containing folder 
        // and try to find .webloc files that point to the same
        // URL we have and that don't have icons
        // 
        NSString *parentDirPath = [resolvedWeblocFilePath stringByDeletingLastPathComponent];
        NSArray *parentDirContents = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:parentDirPath
            error:NULL
            ];
        
        resolvedWeblocFilePath = nil;
        
        if (parentDirContents != nil)
        {
            for (NSString *aFileName in parentDirContents)
            {
                NSString *aFilePath = [parentDirPath stringByAppendingPathComponent:aFileName];
                
                if ([[aFilePath pathExtension] isEqualToString:@"webloc"]
                    && [self.weblocURL isEqualToString:getURLOfWeblocFile(aFilePath)]
                    && !fileHasCustomIcon(aFilePath)
                    )
                {
                    VerbosePrintf(@"    found file with matching URL:\n      %@\n", aFilePath);
                    resolvedWeblocFilePath = aFilePath;
                    break;
                }
            }
        }
    }
    
    return resolvedWeblocFilePath;
}


- (void) drawAndSetIcon
{
    NSImage *newIconImage = [self generatedIconImage];
    NSString *resolvedWeblocFilePath = [self currentWeblocFilePath];
    
    if (resolvedWeblocFilePath == nil)
    {
        PrintfErr(@" -> FAIL: Cannot find file. Must have been moved to another volume or deleted.\n");
        doneIconizing = YES;
        return;
    }
    
    // set icon to file
    [[NSWorkspace sharedWorkspace]
        setIcon:newIconImage
        forFile:resolvedWeblocFilePath
        options:0
        ];
    
    [self setSelfAsDone];
}

- (void) webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if ([self.webView isLoading] || doneIconizing || doneLoadingPage)
        return;
    
    doneLoadingPage = YES;
    
    if (screenshotDelaySec > 0)
    {
        NSInvocation *invocation = [NSInvocation
            invocationWithMethodSignature:[self methodSignatureForSelector:@selector(doneLoading)]
            ];
        [invocation setTarget:self];
        [invocation setSelector:@selector(doneLoading)];
        [NSTimer
            scheduledTimerWithTimeInterval:screenshotDelaySec
            invocation:invocation
            repeats:NO
            ];
        return;
    }
    
    [self doneLoading];
}

- (void) webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    if ([error code] == NSURLErrorCancelled)
        return;
    PrintfErr(@" -> FAIL: %@\n    %@\n    %@\n    %@\n", self.weblocFilePath, self.weblocURL, error, error.userInfo);
    doneIconizing = YES;
}

- (void) webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    if ([error code] == NSURLErrorCancelled)
        return;
    PrintfErr(@" -> FAIL: %@\n    %@\n    %@\n    %@\n", self.weblocFilePath, self.weblocURL, error, error.userInfo);
    doneIconizing = YES;
}

- (void) webView:(WebView *)sender didReceiveIcon:(NSImage *)image forFrame:(WebFrame *)frame
{
    if (!loadFavicon)
        return;
    VerbosePrintf(@" -> got a favicon.\n");
    self.favicon = image;
    [self doneLoading];
}

- (void) webView:(WebView *)sender
         resource:(id)identifier
         didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
         fromDataSource:(WebDataSource *)dataSource
{
    [[challenge sender] cancelAuthenticationChallenge:challenge];
    VerbosePrintf(@" -> FAIL: Server requests authentication.\n");
    doneIconizing = YES;
    [self doneLoading];
}

- (BOOL) saveAliasOfPath:(NSString *)path
{
    OSErr r = FSNewAliasFromPath(
        NULL,   // relative search root
        [path fileSystemRepresentation], // input path
        0,                  // options
        &fileAliasHandle,   // output AliasHandle
        false               // is a dir?
        );
    if (r != noErr)
    {
        fileAliasHandle = NULL;
        return NO;
    }
    return YES;
}

- (NSString *) pathFromSavedAlias
{
    if (fileAliasHandle == NULL)
        return nil;
    
    // resolve alias
    Boolean wasChanged = false;
    FSRef fsRef;
    OSErr r = FSResolveAlias(
        NULL,           // relative search root
        fileAliasHandle,// input AliasHandle
        &fsRef,         // output FSRef
        &wasChanged     // has the file moved?
        );
    if (r != noErr) // probably fnfErr
        return nil;
    
    // FSRef -> NSString
    CFURLRef url = CFURLCreateFromFSRef(kCFAllocatorDefault, &fsRef);
    NSString* path = [(NSURL *)url path];
    CFRelease(url);
    
    if (wasChanged)
        VerbosePrintf(@" -> file had moved: %@\n", path);
    
    return path;
}

@end



int main(int argc, char *argv[])
{
    NSAutoreleasePool *autoReleasePool = [[NSAutoreleasePool alloc] init];
    
    NSApplicationLoad(); // initialize some Cocoa stuff needed by the WebView
    
    char *myBasename = basename(argv[0]);
    if (argc == 1)
    {
        Printf(
            @"%s [options] <path>\n"
            @"\n"
            @"  Sets custom icons for .webloc files that display\n"
            @"  a thumbnail of the web page that they point to.\n"
            @"  <path> may point to a .webloc file or a directory\n"
            @"  that contains .webloc files.\n"
            @"\n"
            @"  Options:\n"
            @"\n"
            @"  -f  Set icons also for files that already have a\n"
            @"      custom icon (they are ignored by default)\n"
            @"  -ni Do not load the site's favicon image and add it to\n"
            @"      the generated icon\n"
            @"  +j  Set Java on when taking screenshots\n"
            @"  -j  Set Java off when taking screenshots (default)\n"
            @"  +js Set JavaScript on when taking screenshots (default)\n"
            @"  -js Set JavaScript off when taking screenshots\n"
            @"  +p  Set browser plugins on when taking screenshots\n"
            @"  -p  Set browser plugins off when taking screenshots (default)\n"
            @"  -d <sec>  Wait for <sec> seconds before taking the\n"
            @"            screenshots\n"
            @"  -v  Make the output verbose.\n"
            @"\n"
            @"%s -a <path>\n"
            @"\n"
            @"  Create a user-specific launch agent for <path> that\n"
            @"  runs this program each time the contents of <path> change\n"
            @"\n"
            @"%s -w\n"
            @"\n"
            @"  List paths that are being watched by user-specific launch agents\n"
            @"\n"
            @"Version %@\n"
            @"Copyright (c) 2009-2013 Ali Rantakari\n"
            @"http://hasseg.org/setWeblocThumb\n"
            @"\n",
            myBasename, myBasename, myBasename,
            versionNumberStr()
            );
        exit(0);
    }
    
    BOOL arg_forceRun = NO;
    BOOL arg_allowPlugins = NO;
    BOOL arg_allowJava = NO;
    BOOL arg_allowJavaScript = YES;
    BOOL arg_favicon = YES;
    BOOL arg_createLaunchAgent = NO;
    BOOL arg_printLaunchAgentWatchPaths = NO;
    NSMutableArray *weblocFilePaths = [NSMutableArray array];
    
    NSString *providedPath = [[NSString stringWithUTF8String:argv[argc-1]] stringByStandardizingPath];
    
    if (1 < argc)
    {
        int i;
        for (i = 1; i < argc; i++)
        {
            if (strcmp(argv[i], "-f") == 0)
                arg_forceRun = YES;
            else if (strcmp(argv[i], "-v") == 0)
                arg_verbose = YES;
            else if (strcmp(argv[i], "-w") == 0)
                arg_printLaunchAgentWatchPaths = YES;
            else if (strcmp(argv[i], "-a") == 0)
                arg_createLaunchAgent = YES;
            else if (strcmp(argv[i], "-ni") == 0)
                arg_favicon = NO;
            else if (strcmp(argv[i], "-js") == 0)
                arg_allowJavaScript = NO;
            else if (strcmp(argv[i], "+js") == 0)
                arg_allowJavaScript = YES;
            else if (strcmp(argv[i], "-j") == 0)
                arg_allowJava = NO;
            else if (strcmp(argv[i], "+j") == 0)
                arg_allowJava = YES;
            else if (strcmp(argv[i], "-p") == 0)
                arg_allowPlugins = NO;
            else if (strcmp(argv[i], "+p") == 0)
                arg_allowPlugins = YES;
            else if ((strcmp(argv[i], "-d") == 0) && (i+1 < argc))
                screenshotDelaySec = abs([[NSString stringWithCString:argv[i+1] encoding:NSUTF8StringEncoding] doubleValue]);
        }
    }
    
    if (arg_printLaunchAgentWatchPaths)
    {
        printLaunchAgentWatchPaths();
        return 0;
    }
    if (arg_createLaunchAgent)
    {
        BOOL success = generateLaunchAgent(providedPath);
        return success ? 0 : 1;
    }
    
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:providedPath isDirectory:&isDir])
    {
        PrintfErr(@"Error: provided path does not exist:\n%s\n\n", [providedPath UTF8String]);
        exit(1);
    }
    if (!isDir && ![[providedPath pathExtension] isEqualToString:@"webloc"])
    {
        PrintfErr(@"Error: specified filename does not have extension: .webloc\n\n");
        exit(1);
    }
    
    if (!isDir)
    {
        [weblocFilePaths addObject:providedPath];
    }
    else
    {
        NSArray *dirContents = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:providedPath
            error:NULL
            ];
        
        if (dirContents != nil)
        {
            NSString *aFile;
            for (aFile in dirContents)
            {
                if ([[aFile pathExtension] isEqualToString:@"webloc"])
                    [weblocFilePaths addObject:[providedPath stringByAppendingPathComponent:aFile]];
            }
        }
    }
    
    
    webViewPrefs = [[[WebPreferences alloc] initWithIdentifier:@"setWeblocThumbWebViewPrefs"] autorelease];
    [webViewPrefs setAllowsAnimatedImages:NO];
    [webViewPrefs setPrivateBrowsingEnabled:YES];
    [webViewPrefs setJavaEnabled:arg_allowJava];
    [webViewPrefs setJavaScriptEnabled:arg_allowJavaScript];
    [webViewPrefs setPlugInsEnabled:arg_allowPlugins];
    
    
    NSMutableArray *weblocIconifiers = [NSMutableArray arrayWithCapacity:[weblocFilePaths count]];
    
    NSString *aFilePath;
    for (aFilePath in weblocFilePaths)
    {
        if (!arg_forceRun && fileHasCustomIcon(aFilePath))
            VerbosePrintf(@"File already has a custom icon: %@\n", aFilePath);
        else
        {
            WeblocIconifier *weblocIconifier = [[[WeblocIconifier alloc] init] autorelease];
            weblocIconifier.weblocFilePath = aFilePath;
            [weblocIconifiers addObject:weblocIconifier];
        }
    }
    
    if ([weblocIconifiers count] == 0)
        exit(0);
    
    
    baseIconImage = [[NSImage alloc] initWithData:(NSData *)[NSData dataWithBase64EncodedString:imgBase64]];
    NSCAssert((baseIconImage != nil), @"baseIconImage is nil");
    
    
    WeblocIconifier *aWeblocIconifier;
    for (aWeblocIconifier in weblocIconifiers)
    {
        [aWeblocIconifier startLoadingWithFavicon:arg_favicon];
    }
    
    
    BOOL isRunning = YES;
    BOOL someStillLoading = YES;
    do
    {
        isRunning = [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]
            ];
        
        someStillLoading = NO;
        for (aWeblocIconifier in weblocIconifiers)
        {
            someStillLoading = ![aWeblocIconifier doneIconizing];
            if (someStillLoading)
                break;
        }
    }
    while(isRunning && someStillLoading);
    
    [baseIconImage release];
    [autoReleasePool release];
    exit(0);
}


