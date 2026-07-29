# frozen_string_literal: true

require_relative "helper"

require "puma/configuration"
require "puma/launcher"
require "puma/cluster"
require "puma/cluster/worker"
require "puma/log_writer"

# `Cluster#warmup_before_fork` (lib/puma/cluster.rb) and
# `Cluster::Worker#warmup_before_fork` (lib/puma/cluster/worker.rb) call
# `Process.warmup` (Ruby 3.3+) right before the master's first worker fork,
# and right before each `fork_worker` refork, respectively. The option
# defaults to +false+ (opt-in) and is validated by the DSL to accept only a
# literal `true`/`false`.
#
# These tests stub `Process.warmup` as a spy and invoke the (private) methods
# directly, rather than driving `Cluster#run` / `Cluster::Worker#run`
# end-to-end: those methods install process-wide signal traps
# (`setup_signals`) and can shell out to `Process.wait`/`Process.waitall`,
# which is unsafe to exercise inside the shared test process -- see the
# warning at the top of test_launcher.rb ("Do not add any tests creating
# workers to this, as Cluster may call `Process.waitall`"). Call-site
# placement (before `spawn_workers` in `Cluster#run`, and inside the `idx ==
# -1` branch right after the `before_refork` hooks in `Worker#run`) is a
# single line each and reviewable directly; what needs a regression test is
# the on/off/no-op/rescue behavior of the method itself, which is what's
# covered here. None of this forks, so (unlike most cluster tests) it runs
# unconditionally -- no `skip_unless :fork` -- including on JRuby/Windows CI.
class TestWarmupBeforeFork < PumaTest
  def test_default_is_false
    conf = Puma::Configuration.new(workers: 2)
    conf.clamp

    assert_equal false, conf.options[:warmup_before_fork]
  end

  def test_dsl_can_enable
    conf = Puma::Configuration.new(workers: 2) { |c| c.warmup_before_fork true }
    conf.clamp

    assert_equal true, conf.options[:warmup_before_fork]
  end

  def test_dsl_can_disable
    conf = Puma::Configuration.new(workers: 2) { |c| c.warmup_before_fork false }
    conf.clamp

    assert_equal false, conf.options[:warmup_before_fork]
  end

  def test_dsl_rejects_non_boolean_string
    conf = Puma::Configuration.new
    error = assert_raises(ArgumentError) { conf.configure { |c| c.warmup_before_fork "false" } }
    assert_includes error.message, "must be true or false"
  end

  def test_dsl_rejects_nil
    conf = Puma::Configuration.new
    error = assert_raises(ArgumentError) { conf.configure { |c| c.warmup_before_fork nil } }
    assert_includes error.message, "must be true or false"
  end

  def test_master_calls_process_warmup_exactly_once_when_enabled
    cluster = build_cluster(warmup_before_fork: true)
    calls = 0

    Process.stub(:warmup, -> { calls += 1 }) do
      cluster.send(:warmup_before_fork)
    end

    assert_equal 1, calls
  end

  def test_master_never_calls_process_warmup_when_disabled
    cluster = build_cluster(warmup_before_fork: false)
    calls = 0

    Process.stub(:warmup, -> { calls += 1 }) do
      cluster.send(:warmup_before_fork)
    end

    assert_equal 0, calls
  end

  def test_master_rescues_and_logs_when_process_warmup_raises
    # If `Cluster#warmup_before_fork` didn't rescue around `Process.warmup`,
    # the `RuntimeError` below would propagate out of `send` and error this
    # test before it ever reached the assertions -- reaching them at all is
    # itself proof the exception didn't propagate.
    log_writer = Puma::LogWriter.strings
    cluster = build_cluster(warmup_before_fork: true, log_writer: log_writer)

    Process.stub(:warmup, -> { raise RuntimeError, "simulated Process.warmup failure" }) do
      cluster.send(:warmup_before_fork)
    end

    assert_match(
      /Process\.warmup raised RuntimeError: simulated Process\.warmup failure .+ continuing boot without warmup/,
      log_writer.stdout.string
    )
  end

  def test_master_is_a_noop_with_debug_log_when_process_warmup_unavailable
    log_writer = Puma::LogWriter.strings
    cluster = build_cluster(warmup_before_fork: true, debug: true, log_writer: log_writer)
    calls = 0

    # Simulate a pre-3.3 Ruby, where `Process` doesn't respond to `:warmup`.
    # Stubbed narrowly -- only `:warmup` reports false, everything else
    # delegates to the real `Process.respond_to?` -- so this can't mask an
    # unrelated `respond_to?` check made by Minitest's own stub/mock
    # machinery (or anything else) during the block.
    original_respond_to = Process.method(:respond_to?)
    warmup_unavailable = ->(name, *rest) { name == :warmup ? false : original_respond_to.call(name, *rest) }

    Process.stub(:respond_to?, warmup_unavailable) do
      Process.stub(:warmup, -> { calls += 1 }) do
        cluster.send(:warmup_before_fork)
      end
    end

    assert_equal 0, calls
    assert_match(/warmup_before_fork is enabled, but Process\.warmup is not available/, log_writer.stdout.string)
  end

  def test_master_warmup_fires_every_invocation_not_just_the_first
    # `Cluster#run` calls `warmup_before_fork` exactly once per master boot,
    # at a single call site right after the `before_fork` hooks and right
    # before `spawn_workers`. Confirm the method fires on every call (i.e.
    # isn't accidentally memoized/latched to only ever run once per process),
    # which is what "once per boot" depends on across repeated boots.
    cluster = build_cluster(warmup_before_fork: true)
    calls = 0

    Process.stub(:warmup, -> { calls += 1 }) do
      cluster.send(:warmup_before_fork)
      cluster.send(:warmup_before_fork)
    end

    assert_equal 2, calls
  end

  def test_worker_refork_calls_process_warmup_exactly_once_when_enabled
    worker = build_worker(warmup_before_fork: true)
    calls = 0

    Process.stub(:warmup, -> { calls += 1 }) do
      worker.send(:warmup_before_fork)
    end

    assert_equal 1, calls
  end

  def test_worker_refork_never_calls_process_warmup_when_disabled
    worker = build_worker(warmup_before_fork: false)
    calls = 0

    Process.stub(:warmup, -> { calls += 1 }) do
      worker.send(:warmup_before_fork)
    end

    assert_equal 0, calls
  end

  def test_worker_refork_rescues_and_logs_when_process_warmup_raises
    # See test_master_rescues_and_logs_when_process_warmup_raises -- same
    # proof-by-reaching-the-assertions reasoning, for the worker/refork call
    # site.
    log_writer = Puma::LogWriter.strings
    worker = build_worker(warmup_before_fork: true, log_writer: log_writer)

    Process.stub(:warmup, -> { raise RuntimeError, "simulated Process.warmup failure" }) do
      worker.send(:warmup_before_fork)
    end

    assert_match(
      /Process\.warmup raised RuntimeError: simulated Process\.warmup failure .+ continuing boot without warmup/,
      log_writer.stdout.string
    )
  end

  def test_worker_refork_is_a_noop_with_debug_log_when_process_warmup_unavailable
    log_writer = Puma::LogWriter.strings
    worker = build_worker(warmup_before_fork: true, debug: true, log_writer: log_writer)
    calls = 0

    original_respond_to = Process.method(:respond_to?)
    warmup_unavailable = ->(name, *rest) { name == :warmup ? false : original_respond_to.call(name, *rest) }

    Process.stub(:respond_to?, warmup_unavailable) do
      Process.stub(:warmup, -> { calls += 1 }) do
        worker.send(:warmup_before_fork)
      end
    end

    assert_equal 0, calls
    assert_match(/warmup_before_fork is enabled, but Process\.warmup is not available/, log_writer.stdout.string)
  end

  def test_worker_refork_warmup_fires_once_per_refork
    # Mirrors test_master_warmup_fires_every_invocation_not_just_the_first,
    # for the fork_worker refork call site: each refork cycle sends worker 0
    # a fresh "-1" (stop server) message, so `warmup_before_fork` should fire
    # exactly once per refork, not just on the first one.
    worker = build_worker(warmup_before_fork: true)
    calls = 0

    Process.stub(:warmup, -> { calls += 1 }) do
      3.times { worker.send(:warmup_before_fork) }
    end

    assert_equal 3, calls
  end

  private

  def build_cluster(warmup_before_fork:, debug: false, log_writer: Puma::LogWriter.strings)
    conf = Puma::Configuration.new(workers: 2, warmup_before_fork: warmup_before_fork, debug: debug)
    launcher = Puma::Launcher.new(conf, log_writer: log_writer)
    Puma::Cluster.new(launcher)
  end

  def build_worker(warmup_before_fork:, debug: false, log_writer: Puma::LogWriter.strings)
    conf = Puma::Configuration.new(
      workers: 2, fork_worker: 0, warmup_before_fork: warmup_before_fork, debug: debug
    )
    launcher = Puma::Launcher.new(conf, log_writer: log_writer)
    Puma::Cluster::Worker.new(index: 0, master: Process.pid, launcher: launcher, pipes: {})
  end
end
