#import "AudioExceptionGuard.h"
#import <os/log.h>
#include <exception>

BOOL RemoteBuddyTryAudioOperation(void (^operation)(void)) {
    try {
        @try {
            operation();
            return YES;
        } @catch (NSException *exception) {
            os_log_error(
                OS_LOG_DEFAULT,
                "Audio operation raised NSException %{public}@: %{public}@",
                exception.name,
                exception.reason
            );
            return NO;
        }
    } catch (const std::exception &exception) {
        os_log_error(
            OS_LOG_DEFAULT,
            "Audio operation threw C++ exception: %{public}s",
            exception.what()
        );
        return NO;
    } catch (...) {
        os_log_error(OS_LOG_DEFAULT, "Audio operation threw unknown C++ exception");
        return NO;
    }
}

BOOL RemoteBuddyTryPlayAudioPlayerNode(AVAudioPlayerNode *player) {
    return RemoteBuddyTryAudioOperation(^{ [player play]; });
}
