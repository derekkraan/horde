## 0.8.0
- `Horde.DynamicSupervisor` behaviour in a netsplit has changed. Previously, when a netsplit heals, `Horde.DynamicSupervisor` would try to clean up any duplicate processes. It no longer does this, leaving that responsibility to `Horde.Registry`.
- `Horde.DynamicSupervisor` and `Horde.Registry` now support the option `members: :auto` to automatically detect other identically-named supervisors or registries.
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
- `Horde.Registry.register/3` returns `{:error, {:already_registered, pid}}` when applicable. This improves compatability with `Elixir.Registry`. [#115](https://github.com/derekkraan/horde/pull/115)
- Adds `Horde.Registry.select/2`, which works the same as `Elixir.Registry.select/2`, which will land in Elixir 1.9. [#110](https://github.com/derekkraan/horde/pull/110)
- Fixes a bug causing `Horde.Supervisor` to crash if a child process was restarting when `Horde.Supervisor.delete_child/2` was called. [#114](https://github.com/derekkraan/horde/pull/114)
