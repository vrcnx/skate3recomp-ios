// iOS/iPadOS counterparts of the macOS AppKit pieces: the ISO and title update
// pickers (UIDocumentPickerViewController) and the title update download
// (NSURLSession instead of the curl command line, since iOS cannot spawn
// processes), plus iOS storage and lifecycle care for saves.

#include <atomic>
#include <filesystem>
#include <string>

#include <SDL3/SDL.h>
#include <rex/cvar.h>
#include <rex/input/input.h>
#include <rex/kernel/guest_presence.h>
#include <rex/kernel/xam/input_injection.h>
#include <rex/logging.h>

REXCVAR_DEFINE_BOOL(skate3_pause_on_background, true, "Skate 3",
                    "iOS: open the game's pause menu when the app loses focus during "
                    "gameplay (app switch, Notification/Control Center, alerts)");

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface Skate3DocumentPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property(nonatomic) BOOL finished;
@property(nonatomic, strong) NSURL* pickedURL;
@end

@implementation Skate3DocumentPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  self.pickedURL = urls.firstObject;
  self.finished = YES;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
  self.finished = YES;
}
@end

@interface Skate3DownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, strong) NSURL* destination;
@property(nonatomic) std::atomic<uint64_t>* copiedBytes;
@property(nonatomic) std::atomic<uint64_t>* totalBytes;
@property(nonatomic, strong) NSString* errorMessage;
@property(nonatomic) BOOL succeeded;
@property(nonatomic, strong) dispatch_semaphore_t done;
@end

@implementation Skate3DownloadDelegate
- (void)URLSession:(NSURLSession*)session
                 downloadTask:(NSURLSessionDownloadTask*)task
                 didWriteData:(int64_t)written
            totalBytesWritten:(int64_t)total_written
    totalBytesExpectedToWrite:(int64_t)expected {
  self.copiedBytes->store(uint64_t(total_written), std::memory_order_relaxed);
  if (expected > 0) {
    self.totalBytes->store(uint64_t(expected), std::memory_order_relaxed);
  }
}
- (void)URLSession:(NSURLSession*)session
                 downloadTask:(NSURLSessionDownloadTask*)task
    didFinishDownloadingToURL:(NSURL*)location {
  // The temporary file is deleted when this returns, so move it now.
  NSInteger status = [task.response isKindOfClass:[NSHTTPURLResponse class]]
                         ? ((NSHTTPURLResponse*)task.response).statusCode
                         : 200;
  if (status < 200 || status >= 300) {
    self.errorMessage = [NSString stringWithFormat:@"HTTP status %ld", long(status)];
    return;
  }
  NSFileManager* files = [NSFileManager defaultManager];
  [files removeItemAtURL:self.destination error:nil];
  NSError* error = nil;
  if ([files moveItemAtURL:location toURL:self.destination error:&error]) {
    self.succeeded = YES;
  } else {
    self.errorMessage = error.localizedDescription;
  }
}
- (void)URLSession:(NSURLSession*)session
                    task:(NSURLSessionTask*)task
    didCompleteWithError:(NSError*)error {
  if (error && !self.errorMessage) {
    self.errorMessage = error.localizedDescription;
  }
  dispatch_semaphore_signal(self.done);
}
@end

namespace skate3 {

namespace {

UIViewController* TopViewController() {
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
      continue;
    }
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (!window.isKeyWindow) {
        continue;
      }
      UIViewController* controller = window.rootViewController;
      while (controller.presentedViewController) {
        controller = controller.presentedViewController;
      }
      return controller;
    }
  }
  return nil;
}

// Presents a document picker and spins the main run loop until it is
// dismissed, like NSOpenPanel's runModal: the install wizards expect the
// picker to return the path synchronously. Must be called on the main thread
// (the wizards pick from their ImGui draw, which runs there).
std::filesystem::path PickFileModally(NSArray<UTType*>* types) {
  @autoreleasepool {
    UIViewController* presenter = TopViewController();
    if (!presenter || ![NSThread isMainThread]) {
      return {};
    }
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    Skate3DocumentPickerDelegate* delegate = [Skate3DocumentPickerDelegate new];
    picker.delegate = delegate;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    picker.directoryURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                               inDomains:NSUserDomainMask]
                              .firstObject;
    [presenter presentViewController:picker animated:YES completion:nil];
    while (!delegate.finished) {
      [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    NSURL* url = delegate.pickedURL;
    if (!url || !url.isFileURL) {
      return {};
    }
    // Files outside the app container (another app's folder, an external
    // drive) are security scoped. The install reads them on a worker thread
    // after this returns, so access is deliberately kept for the process
    // lifetime rather than balanced with stopAccessing.
    [url startAccessingSecurityScopedResource];
    return std::string(url.fileSystemRepresentation);
  }
}

}  // namespace

std::filesystem::path PickIsoFileIOS() {
  NSMutableArray<UTType*>* types = [NSMutableArray array];
  if (UTType* iso = [UTType typeWithFilenameExtension:@"iso"]) {
    [types addObject:iso];
  }
  // Disc images are often shared without a registered type; the installer
  // validates the image itself.
  [types addObject:UTTypeData];
  return PickFileModally(types);
}

std::filesystem::path PickTitleUpdateFileIOS() {
  // The TU package has no extension.
  return PickFileModally(@[ UTTypeItem ]);
}

namespace {

void ExcludeFromBackup(const std::filesystem::path& path) {
  std::error_code ec;
  std::filesystem::create_directories(path, ec);
  NSURL* url = [NSURL fileURLWithFileSystemRepresentation:path.c_str() isDirectory:YES
                                            relativeToURL:nil];
  NSError* error = nil;
  if (![url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error]) {
    REXLOG_WARN("Could not exclude {} from backup: {}", path.string(),
                error.localizedDescription.UTF8String);
  }
}

UIBackgroundTaskIdentifier g_background_task = UIBackgroundTaskInvalid;

void EndBackgroundTask() {
  if (g_background_task != UIBackgroundTaskInvalid) {
    [UIApplication.sharedApplication endBackgroundTask:g_background_task];
    g_background_task = UIBackgroundTaskInvalid;
  }
}

// Runs synchronously from the UIKit app delegate callbacks (main thread).
bool HandleLifecycleEvent(void*, SDL_Event* event) {
  switch (event->type) {
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
      // Press Start for the player so they come back to the pause menu
      // instead of mid-trick. Only while actually skating: the presence
      // context reads 0 in the pause menu, so an open menu is never toggled
      // shut. The guest polls the press as soon as it runs again.
      if (REXCVAR_GET(skate3_pause_on_background) &&
          rex::kernel::guest_presence::GameplayContextValue() == 1) {
        rex::kernel::xam::QueueSyntheticInput(rex::input::X_INPUT_GAMEPAD_START, 8);
        REXLOG_INFO("App lost focus during gameplay: pausing the game");
      }
      // Saves are written by guest threads; without a background task iOS
      // suspends the process mid-write, and a swipe-kill from the app
      // switcher then leaves a truncated save. The grant (~30 s) lets
      // in-flight file I/O finish.
      if (g_background_task == UIBackgroundTaskInvalid) {
        g_background_task = [UIApplication.sharedApplication
            beginBackgroundTaskWithName:@"Finish saving"
                      expirationHandler:^{
                        rex::FlushLogging();
                        EndBackgroundTask();
                      }];
      }
      break;
    case SDL_EVENT_DID_ENTER_BACKGROUND:
      rex::FlushLogging();
      break;
    case SDL_EVENT_DID_ENTER_FOREGROUND:
      EndBackgroundTask();
      break;
    default:
      break;
  }
  return true;
}

}  // namespace

bool QueryIOSPanelPixels(int32_t& width, int32_t& height) {
  // nativeBounds is the panel in pixels, always portrait-up; the app is
  // landscape-only.
  CGRect bounds = UIScreen.mainScreen.nativeBounds;
  const int32_t a = int32_t(bounds.size.width);
  const int32_t b = int32_t(bounds.size.height);
  if (a <= 0 || b <= 0) {
    return false;
  }
  width = std::max(a, b);
  height = std::min(a, b);
  return true;
}

void PrepareIOSStorage(const std::filesystem::path& game_root,
                       const std::filesystem::path& cache_root) {
  // The installed game (gigabytes, reinstallable from the ISO) and caches
  // stay out of iCloud/Finder backups; saves and settings remain backed up.
  ExcludeFromBackup(game_root);
  ExcludeFromBackup(cache_root);

  static bool hooks_installed = false;
  if (!hooks_installed) {
    hooks_installed = true;
    SDL_AddEventWatch(HandleLifecycleEvent, nullptr);
  }
}

bool DownloadToFileIOS(const std::string& url, const std::filesystem::path& destination,
                       std::atomic<uint64_t>& copied_bytes, std::atomic<uint64_t>& total_bytes,
                       std::string& error) {
  @autoreleasepool {
    NSURL* source = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
    if (!source) {
      error = "The configured title update URL is invalid.";
      return false;
    }
    Skate3DownloadDelegate* delegate = [Skate3DownloadDelegate new];
    delegate.destination =
        [NSURL fileURLWithFileSystemRepresentation:destination.c_str() isDirectory:NO
                                     relativeToURL:nil];
    delegate.copiedBytes = &copied_bytes;
    delegate.totalBytes = &total_bytes;
    delegate.done = dispatch_semaphore_create(0);

    NSURLSessionConfiguration* config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    config.timeoutIntervalForResource = 600;
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:delegate
                                                     delegateQueue:[NSOperationQueue new]];
    [[session downloadTaskWithURL:source] resume];
    dispatch_semaphore_wait(delegate.done, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (!delegate.succeeded) {
      error = std::string("The download failed (") +
              (delegate.errorMessage ? delegate.errorMessage.UTF8String : "unknown error") +
              "). Check your internet connection, or select the title update file manually.";
      return false;
    }
    std::error_code ec;
    const auto size = std::filesystem::file_size(destination, ec);
    if (ec || size == 0) {
      error = "The download produced no data.";
      return false;
    }
    total_bytes.store(size, std::memory_order_relaxed);
    copied_bytes.store(size, std::memory_order_relaxed);
    return true;
  }
}

}  // namespace skate3
