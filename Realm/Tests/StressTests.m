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

#import "RLMTestCase.h"

#pragma mark - Models

@interface NamedPointObject : RLMObject
@property NSString *name;
@property NSInteger value;
@end

@implementation NamedPointObject
@end

RLM_ARRAY_TYPE(NamedPointObject)

@interface NamedPointsArrayObject : RLMObject

@property NSString *primaryKey;
@property RLMArray<NamedPointObject> *points;

- (void)addValue:(NSInteger)value;
- (void)trim;

@end

@implementation NamedPointsArrayObject

+ (NSString *)primaryKey
{
    return @"primaryKey";
}

- (void)addValue:(NSInteger)value
{
    NamedPointObject *point = [NamedPointObject new];
    point.name = @"Test";
    point.value = value;
    [self.points addObject:point];
}

- (void)trim
{
    while (self.points.count > 30) {
        [self.points removeObjectAtIndex:0];
    }
}

@end

@interface StressTests : RLMTestCase
@property NSOperationQueue *addQueue;
@end

@implementation StressTests

- (void)setUp
{
    [super setUp];
    self.addQueue = [NSOperationQueue new];
}

- (void)addOperation:(NSString *)primaryKey
{
    [self.addQueue addOperationWithBlock:^{
        usleep((arc4random() % 100000) + 100000);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self addOperation:primaryKey];
        });

        NamedPointsArrayObject *points = [NamedPointsArrayObject objectForPrimaryKey:primaryKey];

        // Create points if necessary
        if (!points) {
            RLMRealm *realm = [RLMRealm defaultRealm];
            [realm beginWriteTransaction];
            points = [NamedPointsArrayObject createOrUpdateInRealm:realm
                                                        withObject:@{@"primaryKey": primaryKey}];
            [realm commitWriteTransaction];
        }

        // Add a random number of NamedPointObjects to points
        [[RLMRealm defaultRealm] beginWriteTransaction];
        NSInteger numPointsToAdd = arc4random() % 10;
        for (NSInteger i = 0; i < numPointsToAdd; i++) {
            [points addValue:arc4random() % 100];
        }
        [points trim];
        [[RLMRealm defaultRealm] commitWriteTransaction];

        // Perform an empty transaction
        [[[NamedPointsArrayObject objectForPrimaryKey:points.primaryKey] realm] transactionWithBlock:^{}];
    }];
}

#pragma mark - Tests

- (void)testTrimmingStressTest {
    XCTestExpectation *passedTimeout = [self expectationWithDescription:@"Passed timeout without exceptions or crashes"];
    for (int i = 0; i < 10; i++) {
        XCTAssertNoThrow([self addOperation:@(i).stringValue]);
    }
    NSTimeInterval timeout = 10;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [passedTimeout fulfill];
    });
    [self waitForExpectationsWithTimeout:timeout + 0.1 handler:nil];
}

@end
