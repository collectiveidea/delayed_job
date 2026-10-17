# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `rake jobs:check` takes a `not_locked` argument to ignore jobs that are currently being worked. ([#1159], [@joshuapinter])

### Changed

- `last_error` now starts with the exception's class name. ([#1232], [@yujideveloper])

### Fixed

- The Active Job adapter raised `NameError` on Rails versions before 7.2, and failed on Rails 4.2. ([#1246], [@raldred])
- Loading the test backend required `ostruct`, which is no longer a default gem as of Ruby 4.0. ([#1245])
- `rake jobs:check` counted jobs scheduled to run in the future. ([#618], [#1159], [@joshuapinter])
- Idle workers on Rails 3.2 and later reloaded the app after every sleep, even when no files had changed. ([#776], [#930], [@stuwil])
- Workers in Rack apps that load ActionDispatch without Rails raised `NameError`. ([#1145], [#1146], [@bazay])
- Delayed module methods were logged as `Module#method` instead of `MyModule.method`. ([#1120], [@xronos-i-am])
- Ruby warned that `Delayed::Worker#max_attempts` and `#max_run_time` were redefined.
- `delayed_job stop` and `status` without `-n` found no workers with daemons 1.2 or later. ([#1080], [#1081], [@TemaMix])

## [4.2.0] - 2025-12-29

### Added

- Pull the Active Job adapter from Rails into Delayed Job for a future Rails release.

### Changed

- Add dependencies on `benchmark` and `logger`, which are moving out of the standard library.
- Add Ruby 4.0 and Rails 8.1 to the test matrix.

## [4.1.13] - 2024-11-08

### Changed

- Enable Rails 8.

## [4.1.12] - 2024-08-14

### Changed

- Multiple contributors on current and legacy test suite improvements.

### Fixed

- Add missing require for `extract_options`.
- Fix Rails 7.2 `ActiveSupport::ProxyObject` deprecation.

## [4.1.12.rc1] - 2024-08-13

### Changed

- Validating trusted publishing release.
- Multiple contributors on current and legacy test suite improvements.

### Fixed

- Add missing require for `extract_options`.
- Fix Rails 7.2 `ActiveSupport::ProxyObject` deprecation.

## [4.1.11] - 2022-09-28

### Fixed

- Fix missing require for Rails 7.0.3+.

## [4.1.10] - 2022-01-17

### Changed

- Support for Rails 7.0. NOTE: If you are using Delayed Job independent of Rails, Active Support 7 has dropped classic dependency autoloading. You will need to add and set up Zeitwerk for autoloading to continue working in Active Support 7.

## [4.1.9] - 2020-12-09

### Added

- Support for parameterized mailers via `delay` call. ([#1121])

### Changed

- Support for Rails 6.1.

## [4.1.8] - 2019-08-16

### Changed

- Support for Rails 6.0.0.

## [4.1.7] - 2019-06-20

### Fixed

- Fix loading `Delayed::PerformableMailer` when ActionMailer isn't loaded yet.

## [4.1.6] - 2019-06-19

### Changed

- Replace `REMOVED` with `FAILED` in log message. ([#1048])
- Misc doc updates. ([#1052], [#1074], [#1064], [#1063])

### Fixed

- Properly initialize ActionMailer outside railties. ([#1077])
- Fix Psych `load_tags` support. ([#1093])

## [4.1.5] - 2018-04-13

### Changed

- Allow Rails 5.2.

## [4.1.4] - 2017-12-29

### Changed

- Use `yaml_tag` instead of deprecated `yaml_as`. ([#996])
- Support Ruby 2.5.0.

## [4.1.3] - 2017-05-26

### Added

- Log an error message when a deserialization error occurs. ([#894])
- Add the queue name to the log output. ([#917])

### Changed

- Add support for Rails 5.1. ([#982])

### Fixed

- Don't mutate the options hash. ([#877])
- Don't include `ClassMethods` with `MessageSending`. ([#924])
- Fix YAML deserialization error if original object is soft-deleted. ([#947])

## [4.1.2] - 2016-05-16

### Added

- `Delayed::Worker.queue_attributes`.

### Changed

- Limit what we require in ActiveSupport.
- Rails 5 support.

### Fixed

- Fix pid file creation when there is no `tmp` directory.

## [4.1.1] - 2015-09-24

### Fixed

- Fix shared specs for backends that reload objects.

## [4.1.0] - 2015-09-22

### Added

- Allow `Delayed::Worker.delay_jobs` configuration to be a proc.
- Add ability to set destroy failed jobs on a per-job basis.
- Set quiet from the environment.

### Changed

- Alter `Delayed::Command` to work with or without Rails.
- Make `Delayed::Worker.new` idempotent.
- Rescue `Exception` instead of `StandardError` in worker.

### Fixed

- Fix worker crash on serialization error.

## [4.0.6] - 2014-12-22

### Changed

- Revert removing test files from the gem.

## [4.0.5] - 2014-12-22

### Added

- Allow user to override where Delayed Job writes log output.
- First attempt at automatic code reloading.

### Changed

- Support for Rails 4.2.
- Clearer error message when ActiveRecord object no longer exists.
- Various improvements to the README.

## [4.0.4] - 2014-09-24

### Added

- Add the ability to set a default queue for a custom job.
- Add the ability to override the `max_run_time` on a custom job. It MUST be lower than the worker setting.
- `SLEEP_DELAY` and `READ_AHEAD` can be set for the rake task.

### Changed

- Psych YAML overrides are now exclusively used only when loading a job payload.
- Some updates for Rails 4.2 support.

### Fixed

- Fix using options passed into `delayed_job` command.

## [4.0.3] - 2014-09-04

### Added

- `--pools` option to `delayed_job` command.

### Changed

- Improved deserialization error reporting.

### Removed

- A bunch of the Psych hacks.

### Fixed

- Misc bug fixes.

## [4.0.2] - 2014-06-24

### Changed

- Add support for RSpec 3.

## [4.0.1] - 2014-04-12

### Changed

- Update gemspec for Rails 4.1.
- Make logger calls more universal.
- Check that records are `persisted?` instead of `new_record?`.

## [4.0.0] - 2013-07-30

### Changed

- Rails 4 compatibility.

### Removed

- Reverted threaded startup due to daemons incompatibilities.

### Fixed

- Attempt to recover from job reservation errors.

## [4.0.0.beta2] - 2013-05-28

### Added

- Threaded startup script for faster multi-worker startup.
- `jobs:check` rake task.

### Changed

- Rails 4 compatibility.
- YAML compatibility changes.

## [4.0.0.beta1] - 2013-03-02

### Changed

- Rails 4 compatibility.

## [3.0.5] - 2013-01-28

### Added

- Psych support for `delayed_job_data_mapper` deserialization.
- User can configure the worker to raise a `SignalException` on `TERM` and/or `INT`.
- Add the ability to run all available jobs and exit when complete.

### Changed

- Better job timeout error logging.

## [3.0.4] - 2012-11-09

### Added

- Allow the app to specify a default queue name.
- Capistrano script now allows user to specify the Delayed Job command, allowing the user to add `bundle exec` if necessary.

### Changed

- Persisted record check is now more general.

## [3.0.3] - 2012-05-25

### Fixed

- Fix a bug where the worker would not respect the exit condition.
- Properly handle sleep delay command line argument.

## [3.0.2] - 2012-04-02

### Added

- Allow the number of jobs read at a time to be configured from the command line using `--read-ahead`.
- Allow custom logger to be configured through `Delayed::Worker.logger`.

### Changed

- Raise `ArgumentError` if attempting to enqueue a performable method on an object that hasn't been persisted yet.
- Various documentation improvements.

### Fixed

- Fix deprecation warnings.

## [3.0.1] - 2012-01-24

### Changed

- Added `RecordNotFound` message to deserialization error.
- Direct JRuby's yecht parser to Syck extensions.
- Test grooming.

### Fixed

- Updated Psych extensions for better compatibility with Ruby 1.9.2.
- Updated Syck extension for increased compatibility with class methods.

## [3.0.0] - 2011-12-30

### Added

- Named queues.
- Job/Worker lifecycle callbacks.

### Changed

- **Breaking:** daemons is no longer a runtime dependency.
- Enqueue hook is called before jobs are saved so that they may be modified.

### Removed

- **Breaking:** Active Record backend support is provided by a separate gem.

### Fixed

- Fix problem deserializing models that use a custom primary key column.
- Fix deserializing ActiveRecord models when the object isn't in the default scope.
- Fix hooks not getting called when `delay_jobs` is false.

## [2.1.4] - 2011-02-11

### Added

- `-p`/`--prefix` option to help differentiate multiple Delayed Job workers on the same host.

### Fixed

- Working around issues when Psych is loaded, fixes issues with Bundler 1.0.10 and Rails 3.0.4.

## [2.1.3] - 2011-01-20

### Added

- `Delayed::Worker.delay_jobs` flag to support running jobs immediately.

### Changed

- Revert worker contention fix due to regressions.

## [2.1.2] - 2010-12-01

### Added

- Job payloads may implement `#max_attempts` to control how many times it should be retried.
- `delayed_job_server_role` Capistrano variable to allow Delayed Job to run on its own worker server:

  ```ruby
  set :delayed_job_server_role, :worker
  ```

### Changed

- Remove contention between multiple workers by performing an update to lock a job before fetching it.

### Fixed

- Fix for loading ActionMailer extension.
- Fix `rake jobs:work` so it outputs to the console.

## [2.1.1] - 2010-11-14

### Fixed

- Fix issue with worker name not getting properly set when locking a job.
- Fixes for YAML serialization.

## [2.1.0] - 2010-11-14

### Added

- `enqueue`, `before`, `after`, `success`, `error`, and `failure` hooks. See the README.
- Rails 3 railtie and generator.
- `--sleep-delay` command line option.

### Changed

- New pure-YAML serialization.
- Changed `@@sleep_delay` to `self.class.sleep_delay` to be consistent with other class variable usage.

### Removed

- **Breaking:** Merb support.
- **Breaking:** All non-Active Record backends, moved into separate gems. See the [Backends wiki page](https://github.com/collectiveidea/delayed_job/wiki/Backends).
- **Breaking:** Rails 2 support. Delayed Job 2.1 will only support Rails 3.

## [2.0.8] - 2013-05-28

### Fixed

- Backport fix for deserialization errors that bring down the daemon.

## [2.0.7] - 2011-02-10

### Fixed

- Fixed missing generators and recipes for Rails 2.x.

## [2.0.6] - 2011-01-20

### Changed

- Revert worker contention fix due to regressions.

## [2.0.5] - 2010-12-01

### Added

- `#reschedule_at` hook on payload to determine when the job should be rescheduled (backported from 2.1).
- `--sleep-delay` command line option (backported from 2.1).
- `delayed_job_server_role` Capistrano variable to allow Delayed Job to run on its own worker server:

  ```ruby
  set :delayed_job_server_role, :worker
  ```

### Changed

- Changed ActiveRecord backend to reserve jobs using an `UPDATE` query to reduce worker contention (backported from 2.1).

## [2.0.4] - 2010-11-14

### Added

- `delayed_job_args` variable for Capistrano recipe to allow configuration of started workers (e.g. `"-n 2 --max-priority 10"`).
- Options to `handle_asynchronously`.
- `Delayed::Worker.default_priority`.
- Allow private methods to be delayed.
- `-m` command line option to start a monitor process.
- `#delay` on `Object` that allows you to delay any method and pass options:

  ```ruby
  options = {:priority => 19, :run_at => 5.minutes.from_now}
  UserMailer.delay(options).deliver_confirmation(@user)
  ```

### Changed

- Normalize logging in worker.

### Deprecated

- `#send_later` and `#send_at` in favor of new `#delay` method.

### Fixed

- Fix issue where dirty tracking prevented job from being properly unlocked.
- Fixes for Ruby 1.9.

## [2.0.3] - 2010-04-16

### Fixed

- Fix initialization for Rails 2.x.

## [2.0.2] - 2010-04-08

### Added

- Railtie to perform Rails 3 initialization. ([3e0fc41f](https://github.com/collectiveidea/delayed_job/commit/3e0fc41f))
- `on_permanent_failure` hook. ([d2f14cd6](https://github.com/collectiveidea/delayed_job/commit/d2f14cd6))

### Changed

- DataMapper backend performance improvements. ([93833cce](https://github.com/collectiveidea/delayed_job/commit/93833cce), [e9b1573e](https://github.com/collectiveidea/delayed_job/commit/e9b1573e), [37a16d11](https://github.com/collectiveidea/delayed_job/commit/37a16d11), [803f2bfa](https://github.com/collectiveidea/delayed_job/commit/803f2bfa))

### Fixed

- Fixes to MongoMapper backend. ([14be7a24](https://github.com/collectiveidea/delayed_job/commit/14be7a24), [dafd5f46](https://github.com/collectiveidea/delayed_job/commit/dafd5f46), [54d40913](https://github.com/collectiveidea/delayed_job/commit/54d40913))
- Fixed `Delayed::Command` to create `tmp/pids` directory. ([8ec8ca41](https://github.com/collectiveidea/delayed_job/commit/8ec8ca41))

## [2.0.1] - 2010-04-03

### Fixed

- Bug fix for using ActiveRecord backend with daemon. (martinbtt)

## [2.0.0] - 2010-04-03

### Added

- Multiple backend support (see README for more details).
- MongoMapper backend. (zbelzer, moneypools)
- DataMapper backend. (lpetre)
- Implemented worker `name_prefix` to maintain dynamic nature of pid detection.

### Changed

- **Breaking:** Reverse priority so the jobs table can be indexed. Lower numbers have higher priority. The default priority is 0, so increase it for jobs that are not important.
- **Breaking:** Move most of the heavy lifting from `Job` to `Worker` (`#work_off`, `#reschedule`, `#run`, `#min_priority`, `#max_priority`, `#max_run_time`, `#max_attempts`, `#worker_name`). (albus522)

### Removed

- **Breaking:** `EvaledJob`. Implement your own if you need this functionality.

### Fixed

- Only use `Time.zone` if it is set. ([#20])
- Fix for `last_error` recording when `destroy_failed_jobs = false`, `max_attempts = 1`.
- Some Rails 3 compatibility fixes. (fredwu)

## [1.8.5] - 2010-03-15

### Changed

- **Breaking:** Replaced `Worker::SLEEP`, `Job::MAX_ATTEMPTS`, and `Job::MAX_RUN_TIME` with class methods that can be overridden.
- Version bump to 1.8.5.

### Fixed

- Set `auto_flushing = true` on Rails logger to fix logging in production.
- Fix error message when trying to `send_later` on a method that doesn't exist.
- Don't use `rails_env` in Capistrano if it's not set. ([#22])
- Delayed Job should append to `delayed_job.log`, not overwrite it.
- Use `Time.zone.now` instead of `Time.now` if set, to honor the app's local time zone.

[Unreleased]: https://github.com/collectiveidea/delayed_job/compare/v4.2.0...HEAD
[4.2.0]: https://github.com/collectiveidea/delayed_job/compare/v4.1.13...v4.2.0
[4.1.13]: https://github.com/collectiveidea/delayed_job/compare/v4.1.12...v4.1.13
[4.1.12]: https://github.com/collectiveidea/delayed_job/compare/v4.1.12.rc1...v4.1.12
[4.1.12.rc1]: https://github.com/collectiveidea/delayed_job/compare/v4.1.11...v4.1.12.rc1
[4.1.11]: https://github.com/collectiveidea/delayed_job/compare/v4.1.10...v4.1.11
[4.1.10]: https://github.com/collectiveidea/delayed_job/compare/v4.1.9...v4.1.10
[4.1.9]: https://github.com/collectiveidea/delayed_job/compare/v4.1.8...v4.1.9
[4.1.8]: https://github.com/collectiveidea/delayed_job/compare/v4.1.7...v4.1.8
[4.1.7]: https://github.com/collectiveidea/delayed_job/compare/v4.1.6...v4.1.7
[4.1.6]: https://github.com/collectiveidea/delayed_job/compare/v4.1.5...v4.1.6
[4.1.5]: https://github.com/collectiveidea/delayed_job/compare/v4.1.4...v4.1.5
[4.1.4]: https://github.com/collectiveidea/delayed_job/compare/v4.1.3...v4.1.4
[4.1.3]: https://github.com/collectiveidea/delayed_job/compare/v4.1.2...v4.1.3
[4.1.2]: https://github.com/collectiveidea/delayed_job/compare/v4.1.1...v4.1.2
[4.1.1]: https://github.com/collectiveidea/delayed_job/compare/v4.1.0...v4.1.1
[4.1.0]: https://github.com/collectiveidea/delayed_job/compare/v4.0.6...v4.1.0
[4.0.6]: https://github.com/collectiveidea/delayed_job/compare/v4.0.5...v4.0.6
[4.0.5]: https://github.com/collectiveidea/delayed_job/compare/v4.0.4...v4.0.5
[4.0.4]: https://github.com/collectiveidea/delayed_job/compare/v4.0.3...v4.0.4
[4.0.3]: https://github.com/collectiveidea/delayed_job/compare/v4.0.2...v4.0.3
[4.0.2]: https://github.com/collectiveidea/delayed_job/compare/v4.0.1...v4.0.2
[4.0.1]: https://github.com/collectiveidea/delayed_job/compare/v4.0.0...v4.0.1
[4.0.0]: https://github.com/collectiveidea/delayed_job/compare/v4.0.0.beta2...v4.0.0
[4.0.0.beta2]: https://github.com/collectiveidea/delayed_job/compare/v4.0.0.beta1...v4.0.0.beta2
[4.0.0.beta1]: https://github.com/collectiveidea/delayed_job/compare/v3.0.5...v4.0.0.beta1
[3.0.5]: https://github.com/collectiveidea/delayed_job/compare/v3.0.4...v3.0.5
[3.0.4]: https://github.com/collectiveidea/delayed_job/compare/v3.0.3...v3.0.4
[3.0.3]: https://github.com/collectiveidea/delayed_job/compare/v3.0.2...v3.0.3
[3.0.2]: https://github.com/collectiveidea/delayed_job/compare/v3.0.1...v3.0.2
[3.0.1]: https://github.com/collectiveidea/delayed_job/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/collectiveidea/delayed_job/compare/v2.1.4...v3.0.0
[2.1.4]: https://github.com/collectiveidea/delayed_job/compare/v2.1.3...v2.1.4
[2.1.3]: https://github.com/collectiveidea/delayed_job/compare/v2.1.2...v2.1.3
[2.1.2]: https://github.com/collectiveidea/delayed_job/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/collectiveidea/delayed_job/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/collectiveidea/delayed_job/compare/v2.0.8...v2.1.0
[2.0.8]: https://github.com/collectiveidea/delayed_job/compare/v2.0.7...v2.0.8
[2.0.7]: https://github.com/collectiveidea/delayed_job/compare/v2.0.6...v2.0.7
[2.0.6]: https://github.com/collectiveidea/delayed_job/compare/v2.0.5...v2.0.6
[2.0.5]: https://github.com/collectiveidea/delayed_job/compare/v2.0.4...v2.0.5
[2.0.4]: https://github.com/collectiveidea/delayed_job/compare/v2.0.3...v2.0.4
[2.0.3]: https://github.com/collectiveidea/delayed_job/compare/v2.0.2...v2.0.3
[2.0.2]: https://github.com/collectiveidea/delayed_job/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/collectiveidea/delayed_job/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/collectiveidea/delayed_job/compare/v1.8.5...v2.0.0
[1.8.5]: https://github.com/collectiveidea/delayed_job/releases/tag/v1.8.5

[#20]: https://github.com/collectiveidea/delayed_job/issues/20
[#22]: https://github.com/collectiveidea/delayed_job/issues/22
[#618]: https://github.com/collectiveidea/delayed_job/issues/618
[#776]: https://github.com/collectiveidea/delayed_job/issues/776
[#877]: https://github.com/collectiveidea/delayed_job/pull/877
[#894]: https://github.com/collectiveidea/delayed_job/pull/894
[#917]: https://github.com/collectiveidea/delayed_job/pull/917
[#924]: https://github.com/collectiveidea/delayed_job/pull/924
[#930]: https://github.com/collectiveidea/delayed_job/pull/930
[#947]: https://github.com/collectiveidea/delayed_job/pull/947
[#982]: https://github.com/collectiveidea/delayed_job/pull/982
[#996]: https://github.com/collectiveidea/delayed_job/pull/996
[#1048]: https://github.com/collectiveidea/delayed_job/pull/1048
[#1052]: https://github.com/collectiveidea/delayed_job/pull/1052
[#1063]: https://github.com/collectiveidea/delayed_job/pull/1063
[#1064]: https://github.com/collectiveidea/delayed_job/pull/1064
[#1074]: https://github.com/collectiveidea/delayed_job/pull/1074
[#1077]: https://github.com/collectiveidea/delayed_job/pull/1077
[#1080]: https://github.com/collectiveidea/delayed_job/issues/1080
[#1081]: https://github.com/collectiveidea/delayed_job/pull/1081
[#1093]: https://github.com/collectiveidea/delayed_job/pull/1093
[#1120]: https://github.com/collectiveidea/delayed_job/pull/1120
[#1121]: https://github.com/collectiveidea/delayed_job/pull/1121
[#1145]: https://github.com/collectiveidea/delayed_job/issues/1145
[#1146]: https://github.com/collectiveidea/delayed_job/pull/1146
[#1159]: https://github.com/collectiveidea/delayed_job/pull/1159
[#1232]: https://github.com/collectiveidea/delayed_job/pull/1232
[#1245]: https://github.com/collectiveidea/delayed_job/issues/1245
[#1246]: https://github.com/collectiveidea/delayed_job/issues/1246

[@bazay]: https://github.com/bazay
[@joshuapinter]: https://github.com/joshuapinter
[@raldred]: https://github.com/raldred
[@stuwil]: https://github.com/stuwil
[@TemaMix]: https://github.com/TemaMix
[@xronos-i-am]: https://github.com/xronos-i-am
[@yujideveloper]: https://github.com/yujideveloper
