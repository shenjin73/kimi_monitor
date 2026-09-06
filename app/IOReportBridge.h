// IOReport private API declarations (exported by IOKit.framework, no public
// header). Used for performance-state residency channels (GPU/CPU frequency).
#ifndef IOReportBridge_h
#define IOReportBridge_h

#include <CoreFoundation/CoreFoundation.h>

typedef void *IOReportSubscriptionRef;

extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group,
                                                   CFStringRef subgroup,
                                                   uint64_t a, uint64_t b,
                                                   uint64_t c);
extern void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b,
                                  CFTypeRef unused);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a,
                                                          CFDictionaryRef channels,
                                                          CFMutableDictionaryRef *subscribedOut,
                                                          uint64_t c,
                                                          CFTypeRef d);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription,
                                             CFDictionaryRef channels,
                                             CFTypeRef a);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef sample1,
                                                  CFDictionaryRef sample2,
                                                  CFTypeRef a);

extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef item);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef item);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef item);
extern int32_t IOReportStateGetCount(CFDictionaryRef item);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef item, int32_t idx);
extern int64_t IOReportStateGetResidency(CFDictionaryRef item, int32_t idx);

#endif /* IOReportBridge_h */
