////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import <Foundation/Foundation.h>

@class RLMRealm;

// A thread which waits for change notifications on the given path and notifies
// all registered RLMRealms when a change occurs. Does *not* retain registered
// RLMRealm instances
@interface RLMChangeListener : NSThread
- (instancetype)initWithPath:(NSString *)path
                    inMemory:(BOOL)inMemory
                       cache:(NSMutableDictionary *)cache;

// This both must be called with `cache` locked
- (void)addRealm:(RLMRealm *)realm;
- (void)removeRealm:(RLMRealm *)realm;
@end
