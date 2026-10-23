#import <Cocoa/Cocoa.h>
// Shared by the application and the isolated visual regression; no radio/audio dependencies.
static inline NSStackView *TX500MakeTransmitSafetyBanner(id target, SEL action, NSTextField **messageLabel) {
    NSTextField *message=[NSTextField wrappingLabelWithString:@""];
    message.textColor=NSColor.systemRedColor;
    message.font=[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    NSButton *ack=[NSButton buttonWithTitle:@"I checked: the radio is on receive" target:target action:action];
    ack.bezelStyle=NSBezelStyleRounded;
    NSTextField *title=[NSTextField labelWithString:@"⚠ Transmit check required"];
    title.textColor=NSColor.systemRedColor; title.font=[NSFont boldSystemFontOfSize:13];
    NSStackView *banner=[NSStackView stackViewWithViews:@[title,message,ack]];
    banner.orientation=NSUserInterfaceLayoutOrientationVertical;
    banner.alignment=NSLayoutAttributeLeading; banner.spacing=8;
    banner.edgeInsets=NSEdgeInsetsMake(12,12,12,12);
    banner.wantsLayer=YES; banner.layer.cornerRadius=8; banner.layer.borderWidth=1;
    banner.layer.borderColor=NSColor.systemRedColor.CGColor;
    if(messageLabel) *messageLabel=message;
    return banner;
}
