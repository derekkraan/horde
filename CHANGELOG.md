# Changelog

## 0.10.0

- Added optional TTL to Horde.DynamicSupervisor's `:proxy_operation` messages. The Time-to-Live defaults to :infinity for full backwards compatibility. This TTL helps prevent potential issues where messages could loop forever between a set of nodes which disagree on which node should execute the task.
- [BREAKING] Horde.DynamicSupervisor's new `:proxy_message_ttl` option configures the maximum TTL for proxy messages. It takes an integer denoting the maximum number of hops a message can travel, or the atom :infinity (default). This can be a breaking change: when upgrading do not set this option to an integer. You can explicity set it to :infinity or leave it default. If this is set to an integer, upgraded nodes won't be able to proxy to non-upgrade nodes.

## 0.9.1

- Fix race condition in registry when node disconnects
- Pass `extra_arguments` flag to the ProcessSupervisor
- Updating libring dependency to ~> 1.7. Needed for upgrade to OTP 27. See [this PR to libring](https://github.com/bitwalker/libring/pull/37) for details.


## 0.9.0

- Bugfixes for scenarios causing Horde to crash. See [#266](https://github.com/derekkraan/horde/pull/266) and [#263](https://github.com/derekkraan/horde/pull/263).
- [BREAKING] The first parameter of `Horde.DistributionStrategy.choose_node/2` has changed from the identifier to the full child spec. See [#239](https://github.com/derekkraan/horde/pull/239).
- Use `:erpc` instead of `:rpc`. See [#265](https://github.com/derekkraan/horde/pull/265).
- Stop eagerly registering processes in Horde.Registry. This solves [#250](https://github.com/derekkraan/horde/issues/250).
- Add `Horde.UniformRandomDistribution` process distribution strategy. See [#252](https://github.com/derekkraan/horde/pull/252).

## 0.8.7
- Tweak dependency on `:telemetry`

## 0.8.6
- Fix an issue with `members: :auto`

## 0.8.5
- Add support for telemetry version 1.0.0

## 0.8.4
- Upgrade to delta_crdt 0.6.0

## 0.8.3
- Fix a deadlock that occurred if a process was being restarted while `Horde.DynamicSupervisor.start_child/2` was being called. [#218](https://github.com/derekkraan/horde/pull/218)
- Respect `max_restarts` and `max_seconds` when given as options to `Horde.DynamicSupervisor.child_spec/1`. [#216](https://github.com/derekkraan/horde/pull/216)

## 0.8.2
- Bump version of `telemetry_poller` dependency. [#212](https://github.com/derekkraan/horde/pull/212)

## 0.8.1
- `Horde.Registry.delete_meta/2` has been added to reflect its addition in `Elixir.Registry` in upcoming release 1.11.0 [#208](https://github.com/derekkraan/horde/pull/208)

## 0.8.0
- `Horde.DynamicSupervisor` behaviour in a netsplit has changed. Previously, when a netsplit heals, `Horde.DynamicSupervisor` would try to clean up any duplicate processes. It no longer does this, leaving that responsibility to `Horde.Registry`. [#196](https://github.com/derekkraan/horde/pull/196)
- `Horde.DynamicSupervisor` and `Horde.Registry` now support the option `members: :auto` to automatically detect other identically-named supervisors or registries. [#184](https://github.com/derekkraan/horde/pull/184)
- `Horde.DynamicSupervisor` now supports the option `process_redistribution: :active` to rebalance processes actively (aka, when a node joins or leaves the cluster). The default is `:passive`, which only redistributes processes when a node dies or loses quorum. [#164](https://github.com/derekkraan/horde/pull/164).

## 0.7.1
- Use MFA for `on_diff` instead of anonymous function, avoids passing around functions (which can be error-prone). [#167](https://github.com/derekkraan/horde/pull/167).

## 0.7.0
- `Horde.Supervisor` has been renamed to `Horde.DynamicSupervisor`.
- `Horde.Registry` and `Horde.Supervisor` now follow the api of `Elixir.DynamicSupervisor` more closely (specifically `init/1` callback and module-based Supervisor / Registry). [#152](https://github.com/derekkraan/horde/pull/152).
- `Horde.Registry.lookup/2` returns `[]` instead of `:undefined` when no match. [#145](https://github.com/derekkraan/horde/pull/145)
- `child_spec/1` can be overridden in `Horde.Registry` and `Horde.Supervisor` [#135](https://github.com/derekkraan/horde/pull/135) [#143](https://github.com/derekkraan/horde/pull/143)
- Implement `:listeners` option for Horde.Registry. [#142](https://github.com/derekkraan/horde/pull/142)
- Fix via tuple usage with meta. [#139](https://github.com/derekkraan/horde/pull/139)

## 0.6.1
- Module-based `Horde.Supervisor` can override `child_spec/1`. [#135](https://github.com/derekkraan/horde/pull/135)
- Added guides for handling clustering, process state handoff (during deploys), and special considerations for eventual consistency to the [documentation](https://hexdocs.pm/horde).
- `Horde.Supervisor` now uses libring to distribute processes over nodes. [#130](https://github.com/derekkraan/horde/pull/130)
- `Horde.Supervisor` publishes metrics with `:telemetry` (`[:horde, :supervisor, :supervised_process_count]`). [#132](https://github.com/derekkraan/horde/pull/132)
- `Horde.Supervisor` and `Horde.Registry` now support option `delta_crdt_options`, which you can use to tune your cluster. Also updated to the most recent DeltaCRDT. [#100](https://github.com/derekkraan/horde/pull/100)

## 0.6.0
- `Horde.Supervisor` now behaves more like `DynamicSupervisor`. [#122](https://github.com/derekkraan/horde/pull/122)
- `Horde.Registry` sends an exit signal to the process that "loses" when a conflict is resolved. [#118](https://github.com/derekkraan/horde/pull/118)
- `Horde.Registry.register/3` returns `{:error, {:already_registered, pid}}` when applicable. This improves compatibility with `Elixir.Registry`. [#115](https://github.com/derekkraan/horde/pull/115)
- Adds `Horde.Registry.select/2`, which works the same as `Elixir.Registry.select/2`, which will land in Elixir 1.9. [#110](https://github.com/derekkraan/horde/pull/110)
- Fixes a bug causing `Horde.Supervisor` to crash if a child process was restarting when `Horde.Supervisor.delete_child/2` was called. [#114](https://github.com/derekkraan/horde/pull/114)
