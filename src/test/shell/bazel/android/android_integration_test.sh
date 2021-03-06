#!/bin/bash
#
# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# For these tests to run do the following:
#
#   1. Install an Android SDK from https://developer.android.com
#   2. Set the $ANDROID_HOME environment variable
#   3. Uncomment the line in WORKSPACE containing android_sdk_repository
#
# Note that if the environment is not set up as above android_integration_test
# will silently be ignored and will be shown as passing.

# Load the test setup defined in the parent directory
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/../../integration_test_setup.sh" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }


function create_android_binary() {
  mkdir -p java/bazel
  cat > java/bazel/BUILD <<EOF
aar_import(
    name = "aar",
    aar = "sample.aar",
)
android_library(
    name = "lib",
    srcs = ["Lib.java"],
    deps = [":aar"],
)
android_binary(
    name = "bin",
    srcs = ["MainActivity.java"],
    manifest = "AndroidManifest.xml",
    deps = [":lib"],
)
EOF

  cp "${TEST_SRCDIR}/io_bazel/src/test/shell/bazel/android/sample.aar" \
    java/bazel/sample.aar
  cat > java/bazel/AndroidManifest.xml <<EOF
  <manifest package="bazel.android" />
EOF

  cat > java/bazel/Lib.java <<EOF
package bazel;
import com.sample.aar.Sample;
public class Lib {
  public static String message() {
  return "Hello Lib" + Sample.getZero();
  }
}
EOF

  cat > java/bazel/MainActivity.java <<EOF
package bazel;

import android.app.Activity;
import android.os.Bundle;

public class MainActivity extends Activity {
  @Override
  public void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
  }
}
EOF
}

function test_sdk_library_deps() {
  create_new_workspace
  setup_android_sdk_support

  mkdir -p java/a
  cat > java/a/BUILD<<EOF
android_library(
    name = "a",
    exports = ["@androidsdk//com.android.support:mediarouter-v7-24.0.0"],
)
EOF

  bazel build --nobuild //java/a:a || fail "build failed"
}

# Regression test for https://github.com/bazelbuild/bazel/issues/1928.
function test_empty_tree_artifact_action_inputs_mount_empty_directories() {
  create_new_workspace
  setup_android_sdk_support
  cat > AndroidManifest.xml <<EOF
<manifest package="com.test"/>
EOF
  mkdir res
  zip test.aar AndroidManifest.xml res/
  cat > BUILD <<EOF
aar_import(
  name = "test",
  aar = "test.aar",
)
EOF
  # Building aar_import invokes the AndroidResourceProcessingAction with a
  # TreeArtifact of the AAR resources as the input. Since there are no
  # resources, the Bazel sandbox should create an empty directory. If the
  # directory is not created, the action thinks that its inputs do not exist and
  # crashes.
  bazel build :test
}

function test_nonempty_aar_resources_tree_artifact() {
  create_new_workspace
  setup_android_sdk_support
  cat > AndroidManifest.xml <<EOF
<manifest package="com.test"/>
EOF
  mkdir -p res/values
  cat > res/values/values.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:android="http://schemas.android.com/apk/res/android">
</resources>
EOF
  zip test.aar AndroidManifest.xml res/values/values.xml
  cat > BUILD <<EOF
aar_import(
  name = "test",
  aar = "test.aar",
)
EOF
  bazel build :test
}

function test_android_sdk_repository_path_from_environment() {
  create_new_workspace
  setup_android_sdk_support
  # Overwrite WORKSPACE that was created by setup_android_sdk_support with one
  # that does not set the path attribute of android_sdk_repository.
  cat > WORKSPACE <<EOF
android_sdk_repository(
    name = "androidsdk",
)
EOF
  ANDROID_HOME=$ANDROID_SDK bazel build @androidsdk//:files || fail \
    "android_sdk_repository failed to build with \$ANDROID_HOME instead of " \
    "path"
}

function test_android_sdk_repository_no_path_or_android_home() {
  create_new_workspace
  cat > WORKSPACE <<EOF
android_sdk_repository(
    name = "androidsdk",
    api_level = 25,
)
EOF
  bazel build @androidsdk//:files >& $TEST_log && fail "Should have failed"
  expect_log "Either the path attribute of android_sdk_repository"
}

function test_android_sdk_repository_wrong_path() {
  create_new_workspace
  mkdir "$TEST_SRCDIR/some_dir"
  cat > WORKSPACE <<EOF
android_sdk_repository(
    name = "androidsdk",
    api_level = 25,
    path = "$TEST_SRCDIR/some_dir",
)
EOF
  bazel build @androidsdk//:files >& $TEST_log && fail "Should have failed"
  expect_log "Unable to read the Android SDK at $TEST_SRCDIR/some_dir, the path may be invalid." \
    " Is the path in android_sdk_repository() or \$ANDROID_SDK_HOME set correctly?"
}

# Check that the build succeeds if an android_sdk is specified with --android_sdk
function test_specifying_android_sdk_flag() {
  create_new_workspace
  setup_android_sdk_support
  create_android_binary
  cat > WORKSPACE <<EOF
android_sdk_repository(
    name = "a",
)
EOF
  ANDROID_HOME=$ANDROID_SDK bazel build --android_sdk=@a//:sdk-24 \
    //java/bazel:bin || fail "build with --android_sdk failed"
}

# Regression test for https://github.com/bazelbuild/bazel/issues/2621.
function test_android_sdk_repository_returns_null_if_env_vars_missing() {
  create_new_workspace
  setup_android_sdk_support
  ANDROID_HOME=/does_not_exist_1 bazel build @androidsdk//:files || \
    fail "Build failed"
  sed -i -e 's/path =/#path =/g' WORKSPACE
  ANDROID_HOME=/does_not_exist_2 bazel build @androidsdk//:files && \
    fail "Build should have failed"
  ANDROID_HOME=$ANDROID_SDK bazel build @androidsdk//:files || "Build failed"
}

function test_allow_custom_manifest_name() {
  create_new_workspace
  setup_android_sdk_support
  create_android_binary
  mv java/bazel/AndroidManifest.xml java/bazel/SomeOtherName.xml

  # macOS requires an argument for the backup file extension.
  sed -i'' -e 's/AndroidManifest/SomeOtherName/' java/bazel/BUILD

  bazel build //java/bazel:bin || fail "Build failed" \
    "Failed to build android_binary with custom Android manifest file name"
}

function test_proguard() {
  create_new_workspace
  setup_android_sdk_support
  mkdir -p java/com/bin
  cat > java/com/bin/BUILD <<EOF
android_binary(
  name = 'bin',
  srcs = ['Bin.java', 'NotUsed.java'],
  manifest = 'AndroidManifest.xml',
  proguard_specs = ['proguard.config'],
  deps = [':lib'],
)
android_library(
  name = 'lib',
  srcs = ['Lib.java'],
)
EOF
  cat > java/com/bin/AndroidManifest.xml <<EOF
<manifest package='com.bin' />
EOF
  cat > java/com/bin/Bin.java <<EOF
package com.bin;
public class Bin {
  public Lib getLib() {
    return new Lib();
  }
}
EOF
  cat > java/com/bin/NotUsed.java <<EOF
package com.bin;
public class NotUsed {}
EOF
  cat > java/com/bin/Lib.java <<EOF
package com.bin;
public class Lib {}
EOF
  cat > java/com/bin/proguard.config <<EOF
-keep public class com.bin.Bin {
  public *;
}
EOF
  assert_build //java/com/bin
  output_classes=$(zipinfo -1 bazel-bin/java/com/bin/bin_proguard.jar)
  assert_equals 3 $(wc -w <<< $output_classes)
  assert_one_of $output_classes "META-INF/MANIFEST.MF"
  assert_one_of $output_classes "com/bin/Bin.class"
  # Not kept by proguard
  assert_not_one_of $output_classes "com/bin/Unused.class"
  # This is renamed by proguard to something else
  assert_not_one_of $output_classes "com/bin/Lib.class"
}

if [[ ! -d "${TEST_SRCDIR}/androidsdk" ]]; then
  echo "Not running Android tests due to lack of an Android SDK."
  exit 0
fi

run_suite "Android integration tests"
