#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>
#include <stdbool.h>
#include <stdlib.h>

#define DOWNRIGHT_SPOTLIGHT_FACTORY_ID "E55A6D2B-5C76-4E83-9C13-6F4BF1D98D77"

// The Markdown parser and metadata policy live in the Swift target. This C
// layer owns only the ABI that mdworker expects from a classic MDImporter.
extern bool DownrightSpotlightPopulateMetadata(
    CFMutableDictionaryRef attributes,
    CFStringRef contentTypeUTI,
    CFStringRef pathToFile
);

static Boolean DownrightImportData(
    void *thisInterface,
    CFMutableDictionaryRef attributes,
    CFStringRef contentTypeUTI,
    CFStringRef pathToFile
);

typedef struct __DownrightMetadataImporter {
    MDImporterInterfaceStruct *interfaceTable;
    CFUUIDRef factoryID;
    UInt32 refCount;
} DownrightMetadataImporter;

static HRESULT DownrightQueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv);
static ULONG DownrightAddRef(void *thisInstance);
static ULONG DownrightRelease(void *thisInstance);

static MDImporterInterfaceStruct DownrightInterfaceTable = {
    NULL,
    DownrightQueryInterface,
    DownrightAddRef,
    DownrightRelease,
    DownrightImportData,
};

static Boolean DownrightImportData(
    void *thisInterface,
    CFMutableDictionaryRef attributes,
    CFStringRef contentTypeUTI,
    CFStringRef pathToFile
) {
    (void)thisInterface;
    return DownrightSpotlightPopulateMetadata(
        attributes, contentTypeUTI, pathToFile
    ) ? true : false;
}

static DownrightMetadataImporter *DownrightAllocate(CFUUIDRef factoryID) {
    DownrightMetadataImporter *instance =
        (DownrightMetadataImporter *)calloc(1, sizeof(DownrightMetadataImporter));
    if (instance == NULL) return NULL;

    instance->interfaceTable = &DownrightInterfaceTable;
    instance->factoryID = (CFUUIDRef)CFRetain(factoryID);
    instance->refCount = 1;
    CFPlugInAddInstanceForFactory(factoryID);
    return instance;
}

static void DownrightDeallocate(DownrightMetadataImporter *instance) {
    CFPlugInRemoveInstanceForFactory(instance->factoryID);
    CFRelease(instance->factoryID);
    free(instance);
}

static HRESULT DownrightQueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv) {
    if (ppv == NULL) return E_POINTER;
    *ppv = NULL;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    if (requested == NULL) return E_OUTOFMEMORY;

    Boolean supported = CFEqual(requested, kMDImporterInterfaceID)
        || CFEqual(requested, IUnknownUUID);
    CFRelease(requested);
    if (!supported) return E_NOINTERFACE;

    DownrightAddRef(thisInstance);
    *ppv = thisInstance;
    return S_OK;
}

static ULONG DownrightAddRef(void *thisInstance) {
    DownrightMetadataImporter *instance = (DownrightMetadataImporter *)thisInstance;
    instance->refCount += 1;
    return instance->refCount;
}

static ULONG DownrightRelease(void *thisInstance) {
    DownrightMetadataImporter *instance = (DownrightMetadataImporter *)thisInstance;
    if (instance->refCount > 0) instance->refCount -= 1;
    if (instance->refCount == 0) {
        DownrightDeallocate(instance);
        return 0;
    }
    return instance->refCount;
}

__attribute__((visibility("default")))
void *MetadataImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    if (!CFEqual(typeID, kMDImporterTypeID)) return NULL;

    CFUUIDRef factoryID = CFUUIDCreateFromString(
        kCFAllocatorDefault,
        CFSTR(DOWNRIGHT_SPOTLIGHT_FACTORY_ID)
    );
    if (factoryID == NULL) return NULL;
    DownrightMetadataImporter *instance = DownrightAllocate(factoryID);
    CFRelease(factoryID);
    return instance;
}
