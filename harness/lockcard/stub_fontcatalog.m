// The two FontCatalog entry points the engine calls, stubbed for the Mac harness: no catalog
// fonts resolve there, so a style's named family falls back to the next in its list, which is
// the fallback the phone shows while a font is still downloading. On the phone the real
// Shared/Fonts/FontCatalog.m provides these; its header imports UIKit, which the harness does
// not build against.
#import <Foundation/Foundation.h>

BOOL SGFontCatalogHasFamily(NSString *family) {
    (void)family;
    return NO;
}

void SGFontCatalogRegisterInstalled(void) {}
