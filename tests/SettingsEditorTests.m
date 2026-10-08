#import <Cocoa/Cocoa.h>
#import <stdlib.h>
#import "../Headers/Lab599ToolsController.h"

static void Check(BOOL ok, NSString *label) { if(!ok) { fprintf(stderr,"FAIL: %s\n",label.UTF8String); exit(1); } }

int main(void) {
    @autoreleasepool {
        Check(getenv("CFFIXED_USER_HOME") != NULL, @"Test preferences must be isolated");
        [NSApplication sharedApplication];
        Lab599ToolsController *tools = [Lab599ToolsController new];
        NSPopUpButton *categories = [tools valueForKey:@"settingsCategoryFilter"];
        Check(categories != nil && [categories itemWithTitle:@"DSP Filters"] != nil, @"Settings has a category pop-up with DSP Filters");

        // A 1024-byte settings block (all zeros: only the items and their categories matter here).
        [tools setValue:[NSMutableData dataWithLength:1024] forKey:@"settingsData"];
        [tools performSelector:@selector(updateSettingsModelFromData)];
        NSArray *all = [tools valueForKey:@"allSettingsItems"];
        NSUInteger dsp = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"category == %@", @"DSP Filters"]].count;
        Check(all.count > dsp && dsp > 0, @"The settings block decodes into several categories");
        Check([[tools valueForKey:@"filteredSettingsItems"] count] == all.count, @"All Categories shows every setting");

        // Choose DSP Filters in the pop-up, as the operator does.
        [categories selectItemWithTitle:@"DSP Filters"];
        NSString *problem = nil;
        @try { [categories sendAction:categories.action to:categories.target]; }
        @catch (NSException *e) { problem = e.reason; }
        NSArray *shownItems = [tools valueForKey:@"filteredSettingsItems"];
        NSUInteger shown = shownItems.count;
        Check(problem == nil && shown == dsp, [NSString stringWithFormat:@"Choosing DSP Filters in the pop-up shows only its %lu settings (shown: %lu of %lu%@%@)",
              (unsigned long)dsp, (unsigned long)shown, (unsigned long)all.count, problem ? @"; " : @"", problem ?: @""]);
        Check([[shownItems valueForKeyPath:@"@distinctUnionOfObjects.category"] isEqual:@[@"DSP Filters"]], @"Every row shown is a DSP Filters setting");
        Check([(NSTableView *)[tools valueForKey:@"settingsTable"] numberOfRows] == (NSInteger)dsp, @"The table itself shows the DSP Filters rows");

        // Another category replaces the first one.
        NSUInteger vfo = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"category == %@", @"VFO & Bands"]].count;
        [categories selectItemWithTitle:@"VFO & Bands"];
        [categories sendAction:categories.action to:categories.target];
        Check(vfo > 0 && [[tools valueForKey:@"filteredSettingsItems"] count] == vfo, @"Choosing VFO & Bands next shows only its settings");

        [categories selectItemWithTitle:@"All Categories"];
        [categories sendAction:categories.action to:categories.target];
        Check([[tools valueForKey:@"filteredSettingsItems"] count] == all.count, @"Choosing All Categories shows every setting again");
        printf("PASS: The Settings category pop-up filters the table (DSP Filters: %lu of %lu settings).\n", (unsigned long)dsp, (unsigned long)all.count);
        printf("ALL SETTINGS EDITOR TESTS PASSED SUCCESSFULLY! ✓\n");
    }
    return 0;
}
