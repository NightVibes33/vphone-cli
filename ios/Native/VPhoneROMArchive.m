#import "VPhoneNativeVM.h"
#import "VPhoneNativeVM.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <zlib.h>

static uint16_t U16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static uint32_t U32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static NSError *BadZip(NSString *message) {
    return [NSError errorWithDomain:@"VPhoneROMArchive" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSString *HexSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [text appendFormat:@"%02x", digest[i]];
    return text;
}
static NSArray<NSString *> *RequiredNames(void) {
    return @[@"AVPBooter.vresearch1.bin", @"AVPSEPBooter.vresearch1.bin",
             @"SHA256SUMS", @"manifest.json"];
}

// This importer only understands the four-file artifact our macOS workflow
// emits. It does not extract arbitrary ZIP paths; no path traversal or
// filesystem writes outside the user-authorized USB folder are possible.
BOOL VPhoneExtractROMArtifact(NSURL *archiveURL, NSURL *usbFolder,
                              NSError * _Nullable * _Nullable error) {
    NSData *archive = [NSData dataWithContentsOfURL:archiveURL
                                           options:NSDataReadingMappedIfSafe
                                             error:error];
    if (!archive) return NO;
    if (archive.length < 22 || archive.length > (uint64_t)64 * 1024 * 1024) {
        if (error) *error = BadZip(@"ROM ZIP is empty or exceeds 64 MB");
        return NO;
    }
    const uint8_t *buf = archive.bytes;
    NSUInteger len = archive.length;
    NSInteger eocd = -1;
    NSUInteger first = len > 65557 ? len - 65557 : 0;
    for (NSInteger pos = (NSInteger)len - 22; pos >= (NSInteger)first; pos--) {
        if (U32(buf + pos) == 0x06054b50) { eocd = pos; break; }
    }
    if (eocd < 0) {
        if (error) *error = BadZip(@"ROM ZIP central directory is missing");
        return NO;
    }
    uint16_t diskNo = U16(buf + eocd + 4);
    uint16_t dirDisk = U16(buf + eocd + 6);
    uint16_t count = U16(buf + eocd + 10);
    uint32_t centralSize = U32(buf + eocd + 12);
    uint32_t centralOffset = U32(buf + eocd + 16);
    if (diskNo || dirDisk || !count || count > 100 ||
        centralOffset > len || centralSize > len - centralOffset) {
        if (error) *error = BadZip(@"Unsupported/malformed ROM artifact ZIP");
        return NO;
    }

    NSMutableDictionary<NSString *, NSData *> *payload = [NSMutableDictionary dictionary];
    uint64_t totalExtracted = 0;
    NSUInteger cursor = centralOffset;
    NSSet *expected = [NSSet setWithArray:RequiredNames()];
    for (NSUInteger i = 0; i < count; i++) {
        if (cursor + 46 > len || U32(buf + cursor) != 0x02014b50) {
            if (error) *error = BadZip(@"Malformed ZIP central entry");
            return NO;
        }
        uint16_t flags = U16(buf + cursor + 8);
        uint16_t method = U16(buf + cursor + 10);
        uint32_t crc = U32(buf + cursor + 16);
        uint32_t compressed = U32(buf + cursor + 20);
        uint32_t expanded = U32(buf + cursor + 24);
        uint16_t filenameLength = U16(buf + cursor + 28);
        uint16_t extraLength = U16(buf + cursor + 30);
        uint16_t commentLength = U16(buf + cursor + 32);
        uint32_t localOffset = U32(buf + cursor + 42);
        uint64_t entryEnd = (uint64_t)cursor + 46 +
            filenameLength + extraLength + commentLength;
        if (entryEnd > len) {
            if (error) *error = BadZip(@"Truncated ZIP central entry");
            return NO;
        }
        NSData *nameData = [NSData dataWithBytes:buf + cursor + 46
                                         length:filenameLength];
        NSString *name = [[NSString alloc] initWithData:nameData
                                              encoding:NSUTF8StringEncoding];
        cursor = (NSUInteger)entryEnd;
        if (!name || ![expected containsObject:name]) continue;
        if ((flags & 1) || (method != 0 && method != 8) ||
            expanded < 1 || expanded > 64 * 1024 * 1024 ||
            (totalExtracted += expanded) > 128 * 1024 * 1024) {
            if (error) *error = BadZip(@"Unsafe ROM ZIP entry");
            return NO;
        }
        if (payload[name]) {
            if (error) *error = BadZip(@"Duplicate ROM ZIP entry");
            return NO;
        }
        if (localOffset > len || len - localOffset < 30 ||
            U32(buf + localOffset) != 0x04034b50) {
            if (error) *error = BadZip(@"Missing ZIP local file header");
            return NO;
        }
        uint64_t compressedOffset = (uint64_t)localOffset + 30 +
            U16(buf + localOffset + 26) + U16(buf + localOffset + 28);
        if (compressedOffset > len || compressed > len - compressedOffset) {
            if (error) *error = BadZip(@"ZIP compressed data out of bounds");
            return NO;
        }
        NSMutableData *output = [NSMutableData dataWithLength:expanded];
        const uint8_t *compressedData = buf + compressedOffset;
        if (method == 0) {
            if (compressed != expanded) {
                if (error) *error = BadZip(@"Invalid uncompressed ZIP entry");
                return NO;
            }
            memcpy(output.mutableBytes, compressedData, expanded);
        } else {
            z_stream stream = {0};
            stream.next_in = (Bytef *)compressedData;
            stream.avail_in = compressed;
            stream.next_out = output.mutableBytes;
            stream.avail_out = expanded;
            if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
                if (error) *error = BadZip(@"Unable to initialize ZIP inflater");
                return NO;
            }
            int inflateStatus = inflate(&stream, Z_FINISH);
            BOOL valid = inflateStatus == Z_STREAM_END &&
                stream.total_in == compressed && stream.total_out == expanded;
            inflateEnd(&stream);
            if (!valid) {
                if (error) *error = BadZip(@"ROM ZIP inflate integrity check failed");
                return NO;
            }
        }
        uLong calculated = crc32(0L, Z_NULL, 0);
        calculated = crc32(calculated, output.bytes, (uInt)output.length);
        if ((uint32_t)calculated != crc) {
            if (error) *error = BadZip(@"ROM ZIP CRC32 mismatch");
            return NO;
        }
        payload[name] = output;
    }
    for (NSString *name in RequiredNames()) {
        if (!payload[name]) {
            if (error) *error = BadZip([@"ROM ZIP missing " stringByAppendingString:name]);
            return NO;
        }
    }
    NSString *checksumText = [[NSString alloc] initWithData:payload[@"SHA256SUMS"]
                                                  encoding:NSUTF8StringEncoding];
    for (NSString *name in @[@"AVPBooter.vresearch1.bin", @"AVPSEPBooter.vresearch1.bin"]) {
        NSString *expectedHash = nil;
        for (NSString *line in [checksumText componentsSeparatedByCharactersInSet:
                                NSCharacterSet.newlineCharacterSet]) {
            NSArray *parts = [line componentsSeparatedByCharactersInSet:
                              NSCharacterSet.whitespaceCharacterSet];
            NSString *hash = parts.firstObject;
            if ([line hasSuffix:name] && hash.length == 64) {
                expectedHash = hash.lowercaseString; break;
            }
        }
        if (!expectedHash || ![HexSHA256(payload[name]) isEqualToString:expectedHash]) {
            if (error) *error = BadZip([@"SHA256 mismatch for " stringByAppendingString:name]);
            return NO;
        }
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *finalDir = [usbFolder URLByAppendingPathComponent:@"VPhone-macOS-host-ROMs"
                                                isDirectory:YES];
    if ([fm fileExistsAtPath:finalDir.path]) {
        if (error) *error = BadZip(@"USB already contains VPhone-macOS-host-ROMs. Remove old folder only if you intend to replace it.");
        return NO;
    }
    NSURL *temporaryDir = [usbFolder URLByAppendingPathComponent:
                           [@".vphone-rom-import-" stringByAppendingString:NSUUID.UUID.UUIDString]
                                                 isDirectory:YES];
    if (![fm createDirectoryAtURL:temporaryDir withIntermediateDirectories:NO
                      attributes:nil error:error]) return NO;
    for (NSString *name in RequiredNames()) {
        if (![payload[name] writeToURL:[temporaryDir URLByAppendingPathComponent:name]
                             options:NSDataWritingAtomic error:error]) {
            [fm removeItemAtURL:temporaryDir error:nil];
            return NO;
        }
    }
    if (![fm moveItemAtURL:temporaryDir toURL:finalDir error:error]) {
        [fm removeItemAtURL:temporaryDir error:nil];
        return NO;
    }
    return YES;
}

@implementation VPhoneROMArchive
+ (BOOL)extract:(NSURL *)archive toUSB:(NSURL *)folder error:(NSError **)error {
    return VPhoneExtractROMArtifact(archive, folder, error);
}
@end
