#ifndef PROCESSFILTER_H
#define PROCESSFILTER_H

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <sys/types.h>

bool client_is_target_pid(pid_t pid, char *pathOut, size_t pathOutLen);
bool client_is_target_audit_token(audit_token_t token, pid_t *pidOut, char *pathOut, size_t pathOutLen);

#endif /* PROCESSFILTER_H */
