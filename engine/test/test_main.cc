// Copyright (c) 2026 ducksdb-mysql-engine contributors.
// SPDX-License-Identifier: GPL-2.0
//
// GoogleTest entry point for the ducksdb-mysql-engine unit suite. Kept separate
// from the test translation units so each test file stays a pure collection of
// TEST() cases (no main()). All targets in engine/test/ link this single main.

#include "gtest/gtest.h"

int main(int argc, char **argv) {
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
