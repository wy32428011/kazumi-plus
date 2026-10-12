# frozen_string_literal: true

# 由 Apple runner 的 RUBYOPT 预加载，版本查询、pod 与 Flutter 子进程共用同一激活约束。
require 'rubygems'

# 先锁定 xcodeproj，避免 CocoaPods 按宽松依赖范围激活已安装的较新版本。
gem 'xcodeproj', "= #{ENV.fetch('KAZUMI_APPLE_XCODEPROJ_VERSION')}"
gem 'cocoapods', "= #{ENV.fetch('KAZUMI_APPLE_COCOAPODS_VERSION')}"
