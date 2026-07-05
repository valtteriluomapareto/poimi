# frozen_string_literal: true

# Ruby dependencies for the TestFlight deploy pipeline (issue #135).
#
# ONLY the deploy tooling lives here — the shipped app has no Ruby dependency.
# CI installs with `bundle install --frozen` against the committed Gemfile.lock, so
# the resolved dependency graph is pinned (supply-chain hardening). Bump fastlane
# by editing the version below and re-running `bundle lock` (never hand-edit the lock).

source "https://rubygems.org"

# fastlane drives the archive → sign → upload-to-TestFlight lanes (fastlane/Fastfile).
# #95 will reuse the same fastlane/ dir for `deliver` (metadata / release notes).
gem "fastlane", "2.236.1"
