#import "VPhoneNativeVM.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <errno.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/time.h>

static NSError *Failure(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.nightvibes33.vphone.vm" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}
static id Make(NSString *name) {
    Class cls = NSClassFromString(name);
    return cls ? [[cls alloc] init] : nil;
}
static id Call(id target, NSString *name, id argument) {
    SEL sel = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, argument);
}
static BOOL Set(id target, NSString *key, id value) {
    if (!target || !value) return NO;
    @try { [target setValue:value forKey:key]; return YES; }
    @catch (NSException *exception) { return NO; }
}
static BOOL SafeName(NSString *name) {
    return name.length && ![name hasPrefix:@"/"] &&
        ![name containsString:@".."] && ![name containsString:@"\\"] ;
}
static id Get(id target, NSString *key) {
    @try { return [target valueForKey:key]; }
    @catch (NSException *exception) { return nil; }
}
@interface VPhoneNativeVM ()
@property (nonatomic, strong) id virtualMachine;
@property (nonatomic, strong) id configuration;
@property (nonatomic, strong) id guestSocketConnection;
@property (nonatomic, assign) int guestControlFD;
@property (nonatomic, assign) BOOL guestControlReady;
@property (nonatomic, strong) NSPipe *serialInput;
@property (nonatomic, strong) NSPipe *serialOutput;
@property (nonatomic, strong) NSMutableString *serialBuffer;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *guestPending;
@end

@implementation VPhoneNativeVM
+ (NSString *)capabilitySummary {
    void *handle = dlopen("/System/Library/Frameworks/Virtualization.framework/Virtualization", RTLD_NOW | RTLD_LOCAL);
    if (!handle) return @"Apple native Virtualization.framework not exposed on iOS";
    BOOL vm = NSClassFromString(@"VZVirtualMachineConfiguration") != Nil;
    BOOL pv3 = NSClassFromString(@"_VZMacHardwareModelDescriptor") != Nil;
    dlclose(handle);
    return [NSString stringWithFormat:@"Framework loaded; VM config %@; PV3 %@; entitlement authorization unproven",
            vm ? @"present" : @"missing", pv3 ? @"present" : @"missing"];
}

- (BOOL)prepareWithBundleURL:(NSURL *)bundleURL error:(NSError **)error {
    self.virtualMachine = nil;
    self.configuration = nil;
    self.guestSocketConnection = nil;
    self.guestControlFD = -1;
    self.guestControlReady = NO;
    self.guestPending = [NSMutableDictionary dictionary];
    self.serialOutput.fileHandleForReading.readabilityHandler = nil;
    self.serialInput = nil;
    self.serialOutput = nil;
    self.serialBuffer = [NSMutableString string];
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfURL:
                              [bundleURL URLByAppendingPathComponent:@"config.plist"]];
    if (!manifest) {
        if (error) *error = Failure(1, @"config.plist cannot be read from selected VM folder.");
        return NO;
    }
    NSString *diskName = [manifest[@"diskImage"] isKindOfClass:NSString.class]
        ? manifest[@"diskImage"] : @"Disk.img";
    if (!SafeName(diskName)) {
        if (error) *error = Failure(2, @"Invalid or escaping disk image path.");
        return NO;
    }
    NSURL *diskURL = [bundleURL URLByAppendingPathComponent:diskName];
    if (![[NSFileManager defaultManager] isReadableFileAtPath:diskURL.path]) {
        if (error) *error = Failure(3, @"The USB VM image is disconnected or not readable.");
        return NO;
    }
    if (!dlopen("/System/Library/Frameworks/Virtualization.framework/Virtualization", RTLD_NOW | RTLD_LOCAL)) {
        if (error) *error = Failure(4, @"No authorized native Virtualization.framework on this iPhone. Metal, JIT, VPN, and pairing cannot grant hypervisor access.");
        return NO;
    }

    @try {
        // Real PV=3 hardware descriptor, as upstream VPhoneHardwareModel.swift.
        id descriptor = Make(@"_VZMacHardwareModelDescriptor");
        Call(descriptor, @"setPlatformVersion:", @(3));
        Call(descriptor, @"setBoardID:", @(0x90));
        Call(descriptor, @"setISA:", @(2));
        id model = Call((id)NSClassFromString(@"VZMacHardwareModel"),
                        @"_hardwareModelWithDescriptor:", descriptor);
        if (!model) {
            if (error) *error = Failure(5, @"PV=3 research hardware model denied/missing.");
            return NO;
        }

        id platform = Make(@"VZMacPlatformConfiguration");
        id identifier = nil;
        NSData *saved = manifest[@"machineIdentifier"];
        id identifierClass = (id)NSClassFromString(@"VZMacMachineIdentifier");
        if ([saved isKindOfClass:NSData.class] && saved.length) {
            identifier = Call([identifierClass alloc], @"initWithDataRepresentation:", saved);
        }
        if (!identifier) identifier = Make(@"VZMacMachineIdentifier");
        if (!Set(platform, @"hardwareModel", model) ||
            !Set(platform, @"machineIdentifier", identifier)) {
            if (error) *error = Failure(6, @"Guest Mac platform/ECID API unavailable.");
            return NO;
        }

        NSString *nvramName = [manifest[@"nvramStorage"] isKindOfClass:NSString.class]
            ? manifest[@"nvramStorage"] : @"nvram.bin";
        if (!SafeName(nvramName)) {
            if (error) *error = Failure(7, @"Unsafe NVRAM path.");
            return NO;
        }
        NSURL *nvramURL = [bundleURL URLByAppendingPathComponent:nvramName];
        id auxClass = (id)NSClassFromString(@"VZMacAuxiliaryStorage");
        id aux = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:nvramURL.path]) {
            aux = Call([auxClass alloc], @"initWithURL:", nvramURL);
        } else {
            SEL create = NSSelectorFromString(@"initCreatingStorageAtURL:hardwareModel:options:error:");
            if ([auxClass instancesRespondToSelector:create]) {
                NSError *underlying = nil;
                aux = ((id (*)(id, SEL, id, id, NSUInteger, NSError **))objc_msgSend)(
                    [auxClass alloc], create, nvramURL, model, (NSUInteger)1, &underlying);
            }
        }
        if (!Set(platform, @"auxiliaryStorage", aux)) {
            if (error) *error = Failure(8, @"NVRAM auxiliary storage API unavailable.");
            return NO;
        }

        NSDictionary *roms = manifest[@"romImages"];
        NSString *romName = [roms isKindOfClass:NSDictionary.class] ? roms[@"avpBooter"] : nil;
        id loader = Make(@"VZMacOSBootLoader");
        if (!SafeName(romName) || !loader) {
            if (error) *error = Failure(9, @"Prepared boot ROM missing from VM manifest.");
            return NO;
        }
        NSURL *romURL = [bundleURL URLByAppendingPathComponent:romName];
        if (![[NSFileManager defaultManager] fileExistsAtPath:romURL.path] ||
            ![loader respondsToSelector:NSSelectorFromString(@"_setROMURL:")]) {
            if (error) *error = Failure(10, @"Prepared ROM unavailable or private bootloader API blocked.");
            return NO;
        }
        Call(loader, @"_setROMURL:", romURL);

        id config = Make(@"VZVirtualMachineConfiguration");
        if (!Set(config, @"bootLoader", loader) ||
            !Set(config, @"platform", platform)) {
            if (error) *error = Failure(11, @"Virtual machine configuration unavailable.");
            return NO;
        }

        // Use real CPU virtualization, capped to leave cores for the iPhone host.
        NSUInteger requestedCPU = [manifest[@"cpuCount"] respondsToSelector:@selector(unsignedIntegerValue)]
            ? [manifest[@"cpuCount"] unsignedIntegerValue] : 4;
        NSUInteger cpu = MAX(2, MIN(requestedCPU, MIN(4, [NSProcessInfo processInfo].activeProcessorCount)));
        uint64_t requestedRAM = [manifest[@"memorySize"] respondsToSelector:@selector(unsignedLongLongValue)]
            ? [manifest[@"memorySize"] unsignedLongLongValue] : (uint64_t)3 * 1024 * 1024 * 1024;
        uint64_t memoryLimit = MIN((uint64_t)4 * 1024 * 1024 * 1024,
                                   [NSProcessInfo processInfo].physicalMemory / 2);
        uint64_t memory = MAX((uint64_t)1024 * 1024 * 1024, MIN(requestedRAM, memoryLimit));
        Set(config, @"cpuCount", @(cpu));
        Set(config, @"memorySize", @(memory));

        // Direct in-place USB image attachment; never copied into the IPA.
        id attachClass = (id)NSClassFromString(@"VZDiskImageStorageDeviceAttachment");
        SEL attachmentInit = NSSelectorFromString(@"initWithURL:readOnly:error:");
        id attachment = nil;
        NSError *diskError = nil;
        if ([attachClass instancesRespondToSelector:attachmentInit]) {
            attachment = ((id (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
                [attachClass alloc], attachmentInit, diskURL, NO, &diskError);
        }
        id block = Call([NSClassFromString(@"VZVirtioBlockDeviceConfiguration") alloc],
                        @"initWithAttachment:", attachment);
        if (!block || !Set(config, @"storageDevices", @[block])) {
            if (error) *error = diskError ?: Failure(12, @"Native guest disk attachment failed.");
            return NO;
        }

        // Real virtual GPU device: host Metal can present only with guest frames.
        id gfx = Make(@"VZMacGraphicsDeviceConfiguration");
        NSDictionary *screen = manifest[@"screenConfig"];
        NSInteger width = [screen[@"width"] respondsToSelector:@selector(integerValue)]
            ? [screen[@"width"] integerValue] : 1290;
        NSInteger height = [screen[@"height"] respondsToSelector:@selector(integerValue)]
            ? [screen[@"height"] integerValue] : 2796;
        NSInteger ppi = [screen[@"pixelsPerInch"] respondsToSelector:@selector(integerValue)]
            ? [screen[@"pixelsPerInch"] integerValue] : 460;
        id displayClass = (id)NSClassFromString(@"VZMacGraphicsDisplayConfiguration");
        SEL displayInit = NSSelectorFromString(@"initWithWidthInPixels:heightInPixels:pixelsPerInch:");
        id display = nil;
        if ([displayClass instancesRespondToSelector:displayInit]) {
            display = ((id (*)(id, SEL, NSInteger, NSInteger, NSInteger))objc_msgSend)(
                [displayClass alloc], displayInit, width, height, ppi);
        }
        if (gfx && display && Set(gfx, @"displays", @[display])) {
            Set(config, @"graphicsDevices", @[gfx]);
        }

        id nat = Make(@"VZNATNetworkDeviceAttachment");
        id net = Make(@"VZVirtioNetworkDeviceConfiguration");
        if (nat && net && Set(net, @"attachment", nat))
            Set(config, @"networkDevices", @[net]);
        id entropy = Make(@"VZVirtioEntropyDeviceConfiguration");
        if (entropy) Set(config, @"entropyDevices", @[entropy]);
        id keyboard = Make(@"VZUSBKeyboardConfiguration");
        if (keyboard) Set(config, @"keyboards", @[keyboard]);
        id vsock = Make(@"VZVirtioSocketDeviceConfiguration");
        if (vsock) Set(config, @"socketDevices", @[vsock]);
        id touch = Make(@"_VZUSBTouchScreenConfiguration");
        if (touch) Call(config, @"_setMultiTouchDevices:", @[touch]);

        // iOS guest requires a SEP coprocessor, just like the upstream Mac host.
        NSString *sepName = [manifest[@"sepStorage"] isKindOfClass:NSString.class]
            ? manifest[@"sepStorage"] : @"SEPStorage";
        if (SafeName(sepName)) {
            id sep = Call([NSClassFromString(@"_VZSEPCoprocessorConfiguration") alloc],
                          @"initWithStorageURL:", [bundleURL URLByAppendingPathComponent:sepName]);
            NSString *sepRom = [roms isKindOfClass:NSDictionary.class] ? roms[@"avpSEPBooter"] : nil;
            if (sep && SafeName(sepRom)) {
                Call(sep, @"setRomBinaryURL:", [bundleURL URLByAppendingPathComponent:sepRom]);
            }
            if (sep) Call(config, @"_setCoprocessors:", @[sep]);
        }


        // Corresponds to upstream VPhoneVirtualMachine.swift audio, accelerators,
        // console and battery configuration (all are real VZ devices).
        id audio = Make(@"VZVirtioSoundDeviceConfiguration");
        id audioInput = Make(@"VZVirtioSoundDeviceInputStreamConfiguration");
        id audioOutput = Make(@"VZVirtioSoundDeviceOutputStreamConfiguration");
        id inputSource = Make(@"VZHostAudioInputStreamSource");
        id outputSink = Make(@"VZHostAudioOutputStreamSink");
        if (audio && audioInput && audioOutput && inputSource && outputSink &&
            Set(audioInput, @"source", inputSource) &&
            Set(audioOutput, @"sink", outputSink) &&
            Set(audio, @"streams", @[audioInput, audioOutput])) {
            Set(config, @"audioDevices", @[audio]);
        }

        NSMutableArray *accelerators = [NSMutableArray array];
        for (NSString *name in @[@"_VZMacVideoToolboxDeviceConfiguration",
                                 @"_VZMacNeuralEngineDeviceConfiguration",
                                 @"_VZMacScalerAcceleratorDeviceConfiguration"]) {
            id item = Make(name);
            if (item) [accelerators addObject:item];
        }
        if (accelerators.count &&
            [config respondsToSelector:NSSelectorFromString(@"_setAcceleratorDevices:")]) {
            Call(config, @"_setAcceleratorDevices:", accelerators);
        }

        id serial = Make(@"_VZPL011SerialPortConfiguration");
        id serialAttachmentClass = (id)NSClassFromString(@"VZFileHandleSerialPortAttachment");
        SEL serialInit = NSSelectorFromString(@"initWithFileHandleForReading:fileHandleForWriting:");
        if (serial && [serialAttachmentClass instancesRespondToSelector:serialInit]) {
            self.serialInput = [NSPipe pipe];
            self.serialOutput = [NSPipe pipe];
            id attachment = ((id (*)(id, SEL, id, id))objc_msgSend)(
                [serialAttachmentClass alloc], serialInit,
                self.serialInput.fileHandleForReading, self.serialOutput.fileHandleForWriting);
            if (attachment && Set(serial, @"attachment", attachment)) {
                Set(config, @"serialPorts", @[serial]);
                __weak typeof(self) weakSelf = self;
                self.serialOutput.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
                    NSData *bytes = handle.availableData;
                    if (!bytes.length) {
                        handle.readabilityHandler = nil;
                        return;
                    }
                    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
                    if (!text) text = [[NSString alloc] initWithData:bytes encoding:NSISOLatin1StringEncoding];
                    if (!text) return;
                    typeof(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    @synchronized (strongSelf) {
                        [strongSelf.serialBuffer appendString:text];
                        if (strongSelf.serialBuffer.length > 600000) {
                            [strongSelf.serialBuffer deleteCharactersInRange:NSMakeRange(0, 150000)];
                        }
                    }
                };
            }
        }

        id batterySource = Make(@"_VZMacSyntheticBatterySource");
        id battery = Make(@"_VZMacBatteryPowerSourceDeviceConfiguration");
        if (batterySource && battery) {
            Call(batterySource, @"setCharge:", @(100.0));
            Call(batterySource, @"setConnectivity:", @(1));
            Call(battery, @"setSource:", batterySource);
            if ([config respondsToSelector:NSSelectorFromString(@"_setPowerSourceDevices:")]) {
                Call(config, @"_setPowerSourceDevices:", @[battery]);
            }
        }

        NSError *validationError = nil;
        SEL validation = NSSelectorFromString(@"validateWithError:");
        BOOL valid = [config respondsToSelector:validation] &&
            ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(config, validation, &validationError);
        if (!valid) {
            if (error) *error = validationError ?: Failure(13, @"Native VM validation rejected by the iPhone host.");
            return NO;
        }
        id vm = Call([NSClassFromString(@"VZVirtualMachine") alloc],
                     @"initWithConfiguration:", config);
        if (!vm) {
            if (error) *error = Failure(14, @"Real VM instantiation denied by native virtualization service.");
            return NO;
        }
        self.configuration = config;
        self.virtualMachine = vm;
        return YES;
    } @catch (NSException *ex) {
        if (error) *error = Failure(15, [NSString stringWithFormat:@"Native VM exception: %@", ex.reason ?: ex.name]);
        return NO;
    }
}

- (void)startWithCompletion:(void (^)(NSError * _Nullable))completion {
    SEL sel = NSSelectorFromString(@"startWithOptions:completionHandler:");
    SEL plain = NSSelectorFromString(@"startWithCompletionHandler:");
    if (!self.virtualMachine || (![self.virtualMachine respondsToSelector:sel] && ![self.virtualMachine respondsToSelector:plain])) {
        completion(Failure(16, @"The native VM start API is unavailable.")); return;
    }
    @try {
        id options = Make(@"VZMacOSVirtualMachineStartOptions");
        if (options && [self.virtualMachine respondsToSelector:sel]) {
            Call(options, @"_setForceDFU:", @(NO));
            ((void (*)(id, SEL, id, id))objc_msgSend)(self.virtualMachine, sel, options, [completion copy]);
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(self.virtualMachine, plain, [completion copy]);
        }
    } @catch (NSException *e) {
        completion(Failure(17, e.reason ?: @"Guest start raised an exception."));
    }
}

#pragma mark - Upstream VPhoneScreenRecorder screenshot transport

- (void)captureRealFrameWithCompletion:(void (^)(UIImage * _Nullable))completion {
    if (!self.virtualMachine) { completion(nil); return; }
    @try {
        NSArray *gpus = Get(self.virtualMachine, @"graphicsDevices");
        id gpu = [gpus isKindOfClass:NSArray.class] ? gpus.firstObject : nil;
        NSArray *displays = Get(gpu, @"displays");
        id display = [displays isKindOfClass:NSArray.class] ? displays.firstObject : nil;
        SEL selector = NSSelectorFromString(@"_takeScreenshotWithCompletionHandler:");
        if (!display || ![display respondsToSelector:selector]) {
            completion(nil); return;
        }
        void (^result)(id) = ^(id output) {
            if ([output isKindOfClass:UIImage.class]) {
                completion(output);
            } else if (output && CFGetTypeID((__bridge CFTypeRef)output) == CGImageGetTypeID()) {
                completion([UIImage imageWithCGImage:(__bridge CGImageRef)output]);
            } else {
                completion(nil);
            }
        };
        ((void (*)(id, SEL, id))objc_msgSend)(display, selector, [result copy]);
    } @catch (NSException *e) {
        completion(nil);
    }
}

#pragma mark - Upstream VPhoneControl protocol (vphoned port 1337)

// The guest RPC framing is: uint32 big endian length + JSON v1.
// This is a real virtio socket, independent from LocalDevVPN/host pairing.
- (BOOL)sendAll:(const void *)bytes count:(NSUInteger)count fd:(int)fd {
    const uint8_t *p = bytes;
    for (NSUInteger i = 0; i < count;) {
        ssize_t n = write(fd, p + i, count - i);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        i += (NSUInteger)n;
    }
    return YES;
}
- (BOOL)receiveAll:(void *)bytes count:(NSUInteger)count fd:(int)fd {
    uint8_t *p = bytes;
    for (NSUInteger i = 0; i < count;) {
        ssize_t n = read(fd, p + i, count - i);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        i += (NSUInteger)n;
    }
    return YES;
}
- (BOOL)sendGuestMessage:(NSDictionary *)message {
    int fd = self.guestControlFD;
    if (fd < 0) return NO;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!payload || payload.length > (1u << 20)) return NO;
    uint32_t length = htonl((uint32_t)payload.length);
    @synchronized(self) {
        return [self sendAll:&length count:sizeof(length) fd:fd] &&
               [self sendAll:payload.bytes count:payload.length fd:fd];
    }
}
- (NSDictionary *)receiveGuestMessage:(int)fd {
    uint32_t lengthBE = 0;
    if (![self receiveAll:&lengthBE count:4 fd:fd]) return nil;
    uint32_t length = ntohl(lengthBE);
    if (!length || length > (1u << 20)) return nil;
    NSMutableData *buffer = [NSMutableData dataWithLength:length];
    if (![self receiveAll:buffer.mutableBytes count:length fd:fd]) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:buffer options:0 error:nil];
    return [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
}
- (void)connectGuestControlWithCompletion:(void (^)(NSString *))completion {
    NSArray *sockets = Get(self.virtualMachine, @"socketDevices");
    id device = [sockets isKindOfClass:NSArray.class] ? sockets.firstObject : nil;
    SEL selector = NSSelectorFromString(@"connectToPort:completionHandler:");
    if (!device || ![device respondsToSelector:selector]) {
        completion(@"VM guest virtio socket not exposed on the iOS host");
        return;
    }
    @try {
        void (^connected)(id, NSError *) = ^(id connection, NSError *connectError) {
            if (!connection || connectError) {
                completion([NSString stringWithFormat:@"vphoned not reachable: %@",
                            connectError.localizedDescription ?: @"guest offline"]);
                return;
            }
            SEL selector = NSSelectorFromString(@"fileDescriptor");
            if (![connection respondsToSelector:selector]) {
                completion(@"Guest socket file descriptor unavailable");
                return;
            }
            int fd = ((int (*)(id, SEL))objc_msgSend)(connection, selector);
            if (fd < 0) { completion(@"Invalid vphoned socket"); return; }
            self.guestControlFD = fd;
            self.guestSocketConnection = connection;
            struct timeval timeout = {.tv_sec = 8, .tv_usec = 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            int noSigPipe = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                if (![self sendGuestMessage:@{@"v": @1, @"t": @"hello"}]) {
                    completion(@"Cannot send vphoned hello");
                    return;
                }
                NSDictionary *hello = [self receiveGuestMessage:fd];
                if (![hello[@"t"] isEqual:@"hello"] || [hello[@"v"] integerValue] != 1) {
                    completion(@"Guest vphoned protocol v1 handshake unavailable");
                    return;
                }
                self.guestControlReady = YES;
                completion([NSString stringWithFormat:@"vphoned: %@; capabilities: %@",
                            hello[@"name"] ?: @"iPhone", hello[@"caps"] ?: @[]]);
                while (self.guestControlReady && self.guestControlFD == fd) {
                    NSDictionary *response = [self receiveGuestMessage:fd];
                    if (!response) break;
                    NSString *requestID = response[@"id"];
                    void (^callback)(NSDictionary *) = nil;
                    if ([requestID isKindOfClass:NSString.class]) {
                        @synchronized (self.guestPending) {
                            callback = self.guestPending[requestID];
                            [self.guestPending removeObjectForKey:requestID];
                        }
                    }
                    if (callback) callback(response);
                }
                self.guestControlReady = NO;
                self.guestControlFD = -1;
                [self failPendingRequests:@"vphoned disconnected"];
            });
        };
        ((void (*)(id, SEL, uint32_t, id))objc_msgSend)(
            device, selector, (uint32_t)1337, [connected copy]);
    } @catch (NSException *e) {
        completion(e.reason ?: @"Guest VSOCK connection failed");
    }
}

#pragma mark - Upstream vphoned request/reply protocol

// Every request carries the same opaque ID echoed by vphoned. Replies are
// delivered from the single VSOCK reader loop, avoiding competing socket reads.
- (void)failPendingRequests:(NSString *)reason {
    NSArray *callbacks = nil;
    @synchronized(self.guestPending) {
        callbacks = self.guestPending.allValues;
        [self.guestPending removeAllObjects];
    }
    for (void (^cb)(NSDictionary *) in callbacks) {
        cb(@{@"t": @"err", @"msg": reason});
    }
}

- (void)requestGuest:(NSDictionary *)payload timeout:(NSTimeInterval)timeout
          completion:(void (^)(NSDictionary *))completion {
    if (!self.guestControlReady || self.guestControlFD < 0) {
        completion(@{@"t": @"err", @"msg": @"vphoned is not connected"});
        return;
    }
    NSString *ident = NSUUID.UUID.UUIDString;
    NSMutableDictionary *message = [payload mutableCopy];
    message[@"v"] = @1;
    message[@"id"] = ident;
    @synchronized(self.guestPending) {
        self.guestPending[ident] = [completion copy];
    }
    if (![self sendGuestMessage:message]) {
        void (^cb)(NSDictionary *) = nil;
        @synchronized(self.guestPending) {
            cb = self.guestPending[ident];
            [self.guestPending removeObjectForKey:ident];
        }
        if (cb) cb(@{@"t": @"err", @"msg": @"Failed to send guest request"});
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        void (^cb)(NSDictionary *) = nil;
        @synchronized(self.guestPending) {
            cb = self.guestPending[ident];
            [self.guestPending removeObjectForKey:ident];
        }
        if (cb) cb(@{@"t": @"err", @"msg": @"Guest request timed out"});
    });
}

- (NSDictionary *)waitForGuest:(NSDictionary *)payload timeout:(NSTimeInterval)timeout {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    [self requestGuest:payload timeout:timeout completion:^(NSDictionary *message) {
        result = message;
        dispatch_semaphore_signal(semaphore);
    }];
    long wait = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                                                 (int64_t)((timeout + 1) * NSEC_PER_SEC)));
    if (wait != 0) return @{@"t": @"err", @"msg": @"Response timeout"};
    return result ?: @{@"t": @"err", @"msg": @"No guest reply"};
}

- (NSError *)errorForReply:(NSDictionary *)reply {
    if (![reply[@"t"] isEqual:@"err"]) return nil;
    NSString *message = [reply[@"msg"] isKindOfClass:NSString.class]
        ? reply[@"msg"] : @"Guest returned an error";
    return Failure(40, message);
}

- (void)listGuestAppsWithCompletion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = [self waitForGuest:@{@"t": @"app_list", @"filter": @"user"} timeout:30];
        NSError *error = [self errorForReply:reply];
        id apps = reply[@"apps"];
        if (!error && ![apps isKindOfClass:NSArray.class]) {
            error = Failure(41, @"Guest app_list response missing apps");
        }
        completion(error ? nil : apps, error);
    });
}

- (void)launchGuestApp:(NSString *)bundleID completion:(void (^)(NSString *, NSError *))completion {
    if (!bundleID.length) {
        completion(nil, Failure(42, @"Missing guest app bundle identifier"));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = [self waitForGuest:@{@"t": @"app_launch", @"bundle_id": bundleID} timeout:30];
        NSError *error = [self errorForReply:reply];
        completion(error ? nil : [NSString stringWithFormat:@"Launched %@ (pid %@)",
                                   bundleID, reply[@"pid"] ?: @"unknown"], error);
    });
}

- (NSDictionary *)uploadGuestFile:(NSURL *)url toPath:(NSString *)destination
                          progress:(void (^)(uint64_t, uint64_t))progress {
    NSError *openError = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:&openError];
    if (!handle) return @{@"t": @"err", @"msg": openError.localizedDescription ?: @"Cannot read IPA"};
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:&openError];
    uint64_t total = [attributes[NSFileSize] unsignedLongLongValue];
    if (!total || total > (uint64_t)20 * 1024 * 1024 * 1024) {
        [handle closeFile];
        return @{@"t": @"err", @"msg": @"Invalid IPA size (maximum 20 GiB)"};
    }

    NSString *ident = NSUUID.UUID.UUIDString;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSDictionary *reply = nil;
    @synchronized(self.guestPending) {
        self.guestPending[ident] = [^(NSDictionary *r) {
            reply = r;
            dispatch_semaphore_signal(semaphore);
        } copy];
    }

    BOOL success = YES;
    int fd = self.guestControlFD;
    @synchronized(self) {
        if (!self.guestControlReady || fd < 0) {
            success = NO;
        } else {
            NSDictionary *header = @{@"v": @1, @"t": @"file_put", @"id": ident,
                                     @"path": destination, @"perm": @"644", @"size": @(total)};
            NSData *json = [NSJSONSerialization dataWithJSONObject:header options:0 error:nil];
            uint32_t length = htonl((uint32_t)json.length);
            success = [self sendAll:&length count:4 fd:fd] &&
                      [self sendAll:json.bytes count:json.length fd:fd];
            uint64_t written = 0;
            while (success && written < total) {
                @autoreleasepool {
                    NSData *chunk = [handle readDataOfLength:(NSUInteger)MIN((uint64_t)65536, total - written)];
                    if (!chunk.length) {
                        success = NO;
                    } else {
                        success = [self sendAll:chunk.bytes count:chunk.length fd:fd];
                        written += chunk.length;
                        if (success && progress) progress(written, total);
                    }
                }
            }
        }
    }
    [handle closeFile];
    if (!success) {
        void (^cb)(NSDictionary *) = nil;
        @synchronized(self.guestPending) {
            cb = self.guestPending[ident];
            [self.guestPending removeObjectForKey:ident];
        }
        if (cb) cb(@{@"t": @"err", @"msg": @"Guest file transfer failed or USB disconnected"});
    }
    long wait = dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)));
    if (wait != 0) {
        @synchronized(self.guestPending) {
            [self.guestPending removeObjectForKey:ident];
        }
        return @{@"t": @"err", @"msg": @"Guest file transfer reply timed out"};
    }
    return reply ?: @{@"t": @"err", @"msg": @"Guest file transfer failed"};
}

- (void)installGuestIPAAtURL:(NSURL *)url
                   progress:(void (^)(uint64_t, uint64_t))progress
                 completion:(void (^)(NSString *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scope = [url startAccessingSecurityScopedResource];
        @try {
            if (!self.guestControlReady) {
                completion(nil, Failure(43, @"Guest vphoned is not connected"));
                return;
            }
            NSString *folder = @"/var/mobile/Documents/vphone-installs";
            NSString *name = [NSString stringWithFormat:@"%@.ipa", NSUUID.UUID.UUIDString];
            NSString *remotePath = [folder stringByAppendingPathComponent:name];
            NSDictionary *mkdir = [self waitForGuest:@{@"t": @"file_mkdir", @"path": folder} timeout:30];
            NSError *error = [self errorForReply:mkdir];
            if (error) { completion(nil, error); return; }
            NSDictionary *upload = [self uploadGuestFile:url toPath:remotePath progress:progress];
            error = [self errorForReply:upload];
            if (error) { completion(nil, error); return; }
            NSDictionary *installed = [self waitForGuest:@{@"t": @"ipa_install",
                @"path": remotePath, @"registration": @"User"} timeout:180];
            error = [self errorForReply:installed];
            // Keep cleanup best-effort, but do not turn a successful install into failure.
            [self waitForGuest:@{@"t": @"file_delete", @"path": remotePath} timeout:30];
            completion(error ? nil : (installed[@"msg"] ?: @"IPA installed inside guest"), error);
        } @catch (NSException *exception) {
            completion(nil, Failure(44, exception.reason ?: @"Guest installer failed"));
        } @finally {
            if (scope) [url stopAccessingSecurityScopedResource];
        }
    });
}

- (NSString *)serialLogSnapshot {
    @synchronized(self) {
        return [self.serialBuffer copy] ?: @"";
    }
}
- (BOOL)sendHIDPressWithPage:(uint32_t)page usage:(uint32_t)usage {
    if (!self.guestControlReady || self.guestControlFD < 0) return NO;
    // Exact vphoned HID command format, identical to upstream VPhoneKeyHelper.
    return [self sendGuestMessage:@{@"v": @1, @"t": @"hid",
                                    @"id": NSUUID.UUID.UUIDString,
                                    @"page": @(page), @"usage": @(usage)}];
}

- (BOOL)sendTouchWithPhase:(NSInteger)phase x:(double)x y:(double)y {
    if (!self.guestControlReady || self.guestControlFD < 0) return NO;
    return [self sendGuestMessage:@{@"v": @1, @"t": @"touch",
                                    @"id": NSUUID.UUID.UUIDString,
                                    @"phase": @(phase),
                                    @"x": @(MAX(0.0, MIN(1.0, x))),
                                    @"y": @(MAX(0.0, MIN(1.0, y)))}];
}

- (void)stopWithCompletion:(void (^)(NSError * _Nullable))completion {
    self.guestControlReady = NO;
    self.guestControlFD = -1;
    self.guestSocketConnection = nil;
    self.serialOutput.fileHandleForReading.readabilityHandler = nil;
    if (!self.virtualMachine) { completion(nil); return; }
    SEL sel = NSSelectorFromString(@"stopWithCompletionHandler:");
    @try {
        if ([self.virtualMachine respondsToSelector:sel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self.virtualMachine, sel, [completion copy]);
        } else {
            SEL request = NSSelectorFromString(@"requestStopWithError:");
            NSError *underlying = nil;
            BOOL ok = [self.virtualMachine respondsToSelector:request] &&
                ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(self.virtualMachine, request, &underlying);
            completion(ok ? nil : (underlying ?: Failure(18, @"VM stop API unavailable.")));
        }
    } @catch (NSException *e) {
        completion(Failure(19, e.reason ?: @"VM stop raised an exception."));
    }
}
@end
