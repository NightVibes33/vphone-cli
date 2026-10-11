#import "VPhoneNativeVM.h"
#import <objc/message.h>
#import <dlfcn.h>

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
    SEL sel = NSSelectorFromString(@"startWithCompletionHandler:");
    if (!self.virtualMachine || ![self.virtualMachine respondsToSelector:sel]) {
        completion(Failure(16, @"The native VM start API is unavailable.")); return;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(self.virtualMachine, sel, [completion copy]);
    } @catch (NSException *e) {
        completion(Failure(17, e.reason ?: @"Guest start raised an exception."));
    }
}
- (void)stopWithCompletion:(void (^)(NSError * _Nullable))completion {
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
