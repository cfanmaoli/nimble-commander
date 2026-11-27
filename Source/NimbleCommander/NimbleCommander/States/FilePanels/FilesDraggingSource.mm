// Copyright (C) 2016-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "FilesDraggingSource.h"
#include <VFS/Native.h>
#include <Utility/StringExtras.h>
#include <Operations/Deletion.h>
#include <Operations/Copying.h>
#include <Operations/Operation.h>
#include <Base/dispatch_cpp.h>
#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <vector>
#include <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "PanelController.h"
#include "MainWindowFilePanelState.h"
#include "../MainWindowController.h"

static const auto g_PrivateDragUTI = @"com.magnumbytes.nimblecommander.filespanelsdraganddrop";

namespace {

struct PromiseOperationRegistry {
    std::mutex mutex;
    std::vector<std::shared_ptr<nc::ops::Operation>> operations;
};

PromiseOperationRegistry &PromiseOperations()
{
    // Intentionally leaked: file promises can outlive the app's normal teardown, and this avoids
    // an exit-time destructor for a global container.
    static auto *const registry = new PromiseOperationRegistry;
    return *registry;
}

void RetainPromiseOperation(const std::shared_ptr<nc::ops::Operation> &_operation)
{
    PromiseOperationRegistry &registry = PromiseOperations();
    const std::lock_guard lock(registry.mutex);
    registry.operations.emplace_back(_operation);
}

void ReleasePromiseOperation(const std::shared_ptr<nc::ops::Operation> &_operation)
{
    PromiseOperationRegistry &registry = PromiseOperations();
    const std::lock_guard lock(registry.mutex);
    const auto it = std::ranges::find(registry.operations, _operation);
    if( it != registry.operations.end() )
        registry.operations.erase(it);
}

NSError *PromiseCopyError()
{
    return [NSError errorWithDomain:@"info.filesmanager.Files.promise"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: @"Copy failed"}];
}

} // namespace

// "com.apple.pasteboard.promised-file-url"
static const auto g_PasteboardFileURLPromiseUTI = static_cast<NSString *>(kPasteboardTypeFileURLPromise);

// "public.file-url"
static const auto g_PasteboardFileURLUTI = NSPasteboardTypeFileURL;

@implementation PanelDraggingItem {
    VFSListingItem m_Item;
}
@synthesize item = m_Item;
@synthesize icon;

- (PanelDraggingItem *)initWithItem:(const VFSListingItem &)_item
{
    self = [super init];
    if( self ) {
        m_Item = _item;
    }
    return self;
}

- (void)reset
{
    m_Item = VFSListingItem();
}

@end

@implementation PanelDraggingFilePromiseProvider {
    VFSListingItem m_Item;
    VFSHostPtr m_NativeHost;
}

- (instancetype)initWithItem:(const VFSListingItem &)_item nativeHost:(const VFSHostPtr &)_native_host
{
    const auto type = _item.IsDir() ? UTTypeFolder.identifier : UTTypeData.identifier;
    self = [super initWithFileType:type delegate:self];
    if( self ) {
        m_Item = _item;
        m_NativeHost = _native_host;
    }
    return self;
}

- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    NSMutableArray<NSPasteboardType> *const types = [[super writableTypesForPasteboard:pasteboard] mutableCopy];
    [types addObject:g_PrivateDragUTI];
    return types;
}

- (id)pasteboardPropertyListForType:(NSPasteboardType)type
{
    if( [type isEqualToString:g_PrivateDragUTI] )
        return [NSData data];
    return [super pasteboardPropertyListForType:type];
}

- (NSString *)filePromiseProvider:(NSFilePromiseProvider *) [[maybe_unused]] _provider
                  fileNameForType:(NSString *) [[maybe_unused]] _file_type
{
    return m_Item.FilenameNS();
}

- (NSOperationQueue *)operationQueueForFilePromiseProvider:(NSFilePromiseProvider *) [[maybe_unused]] _provider
{
    static NSOperationQueue *const queue = [] {
        NSOperationQueue *const q = [NSOperationQueue new];
        q.maxConcurrentOperationCount = 2;
        q.name = @"com.magnumbytes.nimblecommander.file-promise-writer";
        return q;
    }();
    return queue;
}

- (void)filePromiseProvider:(NSFilePromiseProvider *) [[maybe_unused]] _provider
          writePromiseToURL:(NSURL *)_url
          completionHandler:(void (^)(NSError *_Nullable))_completion_handler
{
    const char *const destination = _url.path.fileSystemRepresentation;
    if( destination == nullptr || *destination == 0 ) {
        _completion_handler([NSError errorWithDomain:@"info.filesmanager.Files.promise"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid destination URL"}]);
        return;
    }

    nc::ops::CopyingOptions options;
    options.docopy = true;
    options.preserve_symlinks = true;
    options.copy_xattrs = true;
    options.copy_file_times = true;
    options.copy_unix_flags = true;
    options.copy_unix_owners = true;
    options.exist_behavior = nc::ops::CopyingOptions::ExistBehavior::Stop;

    const auto operation =
        std::make_shared<nc::ops::Copying>(std::vector<VFSListingItem>{m_Item}, destination, m_NativeHost, options);
    const auto completion_called = std::make_shared<std::atomic_bool>(false);
    const std::weak_ptr<nc::ops::Operation> weak_operation = operation;
    const auto finish = [completion_called, _completion_handler](NSError *_Nullable _error) {
        if( completion_called->exchange(true) )
            return;
        _completion_handler(_error);
    };

    bool started = false;
    bool has_after_hook = false;
    try {
        RetainPromiseOperation(operation);
        // Capture only a weak_ptr here: the callback lives on the Job owned by the Operation, so a
        // strong capture would create a reference cycle. Job::Run() invokes it only after
        // Job::Execute() has unwound.
        has_after_hook = operation->SetAfterJobFinishedCallback([weak_operation] {
            dispatch_to_main_queue([weak_operation] {
                if( const auto op = weak_operation.lock() )
                    ReleasePromiseOperation(op);
            });
        });
        operation->ObserveUnticketed(nc::ops::Operation::NotifyAboutFinish, [weak_operation, finish, has_after_hook] {
            if( const auto op = weak_operation.lock() ) {
                finish(op->State() == nc::ops::OperationState::Completed ? nil : PromiseCopyError());
            }
            else {
                // The retained table should make this unreachable, but never leave the receiver
                // waiting if it happens.
                finish(PromiseCopyError());
            }
            if( !has_after_hook ) {
                dispatch_to_main_queue([weak_operation] {
                    if( const auto op = weak_operation.lock() )
                        ReleasePromiseOperation(op);
                });
            }
        });
        operation->Start();
        started = true;
    } catch( ... ) {
        finish(PromiseCopyError());
        if( !started ) {
            dispatch_to_main_queue([weak_operation] {
                if( const auto op = weak_operation.lock() )
                    ReleasePromiseOperation(op);
            });
        }
    }
}

@end

@implementation FilesDraggingSource {
    std::vector<PanelDraggingItem *> m_Items;
    __weak PanelController *m_SourceController;
    VFSHostPtr m_CommonHost;
    bool m_AreAllHostsWriteable;
    bool m_AreAllHostsNative;
}

@synthesize areAllHostsWriteable = m_AreAllHostsWriteable;
@synthesize areAllHostsNative = m_AreAllHostsNative;
@synthesize commonHost = m_CommonHost;
@synthesize items = m_Items;
@synthesize sourceController = m_SourceController;

+ (NSString *)privateDragUTI
{
    return g_PrivateDragUTI;
}
+ (NSString *)fileURLsPromiseDragUTI
{
    return g_PasteboardFileURLPromiseUTI;
}
+ (NSString *)fileURLsDragUTI
{
    return g_PasteboardFileURLUTI;
}

- (FilesDraggingSource *)initWithSourceController:(PanelController *)_controller
{
    self = [super init];
    if( self ) {
        m_SourceController = _controller;
        m_AreAllHostsWriteable = false;
        m_AreAllHostsNative = false;
    }
    return self;
}

- (void)addItem:(PanelDraggingItem *)_item
{
    if( m_Items.empty() ) {
        m_CommonHost = _item.item.Host();
        m_AreAllHostsNative = m_CommonHost->IsNativeFS();
        m_AreAllHostsWriteable = m_CommonHost->IsWritable();
    }
    else {
        if( m_CommonHost && _item.item.Host() != m_CommonHost )
            m_CommonHost = nullptr;
        if( m_AreAllHostsNative && !_item.item.Host()->IsNativeFS() )
            m_AreAllHostsNative = false;
        if( m_AreAllHostsWriteable && !_item.item.Host()->IsWritable() )
            m_AreAllHostsWriteable = false;
    }

    m_Items.emplace_back(_item);
}

- (NSDragOperation)draggingSession:(NSDraggingSession *) [[maybe_unused]] _session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    switch( context ) {
        case NSDraggingContextOutsideApplication:
            if( m_AreAllHostsNative && m_AreAllHostsWriteable )
                return NSDragOperationCopy | NSDragOperationLink | NSDragOperationGeneric | NSDragOperationMove |
                       NSDragOperationDelete;
            else
                return NSDragOperationCopy;

        case NSDraggingContextWithinApplication:
            if( m_AreAllHostsNative )
                return NSDragOperationCopy | NSDragOperationLink | NSDragOperationGeneric | NSDragOperationMove;
            else
                return NSDragOperationCopy | NSDragOperationGeneric | NSDragOperationMove;

        default:
            return NSDragOperationNone;
    }
}

// From Apple's doc:
//    The recommended approach for writing URLs to the pasteboard is as follows:
//    NSArray *arrayOfURLs; // assume this exists
//    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard]; // get pasteboard
//    [pasteboard clearContents]; // clear pasteboard to take ownership
//    [pasteboard writeObjects:arrayOfURLs]; // write the URLs
- (void)writeURLsPBoard:(NSPasteboard *)_sender
{
    NSMutableArray *urls = [NSMutableArray new];
    for( auto &i : m_Items )
        if( i.item.Host()->IsNativeFS() ) {
            auto url = [NSURL fileURLWithPath:[NSString stringWithUTF8StdString:i.item.Path()]];
            [urls addObject:url];
        }

    if( urls.count )
        [_sender writeObjects:urls];
}

- (void)draggingSession:(NSDraggingSession *) [[maybe_unused]] session
           endedAtPoint:(NSPoint) [[maybe_unused]] screenPoint
              operation:(NSDragOperation)operation
{
    if( operation == NSDragOperationDelete ) {
        [self deleteSoureItems];
    }

    for( auto &item : m_Items )
        [item reset];

    m_Items.clear();
    m_CommonHost = nullptr;
}

static void AddPanelRefreshEpilogIfNeeded(PanelController *_target, nc::ops::Operation &_operation)
{
    __weak PanelController *weak_panel = _target;
    _operation.ObserveUnticketed(nc::ops::Operation::NotifyAboutFinish, [=] {
        dispatch_to_main_queue([=] {
            if( PanelController *const strong_pc = weak_panel )
                [strong_pc hintAboutFilesystemChange];
        });
    });
}

- (void)deleteSoureItems
{
    if( PanelController *target = m_SourceController ) {
        std::vector<VFSListingItem> items;
        for( auto &i : m_Items )
            items.push_back(i.item);

        const auto operation = std::make_shared<nc::ops::Deletion>(items, nc::ops::DeletionType::Trash);

        AddPanelRefreshEpilogIfNeeded(target, *operation);
        [target.mainWindowController enqueueOperation:operation];
    }
}

@end
