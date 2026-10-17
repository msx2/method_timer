# MethodTimer

Per-method timing for Ruby code, for profiling interactively from a console. It instruments every method under a
class or namespace and reports, per method: self and total time, SQL time, GC time, call count and allocations.
Wrappers are allocation-free, and the report includes an estimate of the profiler's own overhead.

**This is a console tool: use it from an interactive console session, never from application code.** Running it
in a production console against real data is fine and a common use. Don't call it from code that serves requests or
runs jobs: instrumentation patches classes until you `uninstall`, adds a fixed cost to every
instrumented call, keeps global state and isn't thread-safe. Profile in a throwaway console session (e.g.
`rails console`), then exit.

Requires Ruby 3.4+: the wrappers forward arguments with `(...)`, which only stopped allocating in Ruby 3.4 (on
older versions every instrumented call would add objects to the `allocs` column). No runtime dependencies; SQL is
tracked automatically when ActiveSupport is loaded (ActiveRecord's `sql.active_record` notifications).

## Installation

Add it with `require: false`, so it's installed everywhere you might open a console but never loaded when the app
boots:

```ruby
# Gemfile
gem 'method_timer', require: false
```

If you only profile locally, put it in the development group instead.

Then load it in the console session where you want to profile:

```ruby
require 'method_timer'
```

### Loading it in every Rails console

Use Rails' `console` hook in `config/application.rb`, which runs only when a console starts (not in the server,
jobs or tests):

```ruby
module MyApp
  class Application < Rails::Application
    console do
      require 'method_timer' if Gem.loaded_specs.key?('method_timer')
    end
  end
end
```

The `Gem.loaded_specs` guard keeps consoles starting in environments where the gem isn't installed (e.g. when it's
in the development group and you open a production console).

## Usage

MethodTimer works with any Ruby code: plain classes and modules, Rails models and services, or classes from other
gems. Point `install` at a class or a namespace; every instance method defined there (public, protected and
private, plus methods of modules included directly into those classes) gets timed.

### Where does the time go?

```ruby
MethodTimer.install(MyApp::Billing)              # a class or a namespace (all classes under it)
MethodTimer.run { thing_to_profile }             # prints the report to stderr, returns the block's value
MethodTimer.run(rss: true) { thing_to_profile }  # also samples peak process memory every second
MethodTimer.report(threshold: 0.5)               # reprint, showing only methods with total >= 0.5s (default 0.001s)
MethodTimer.stats                                # the numbers as a hash
MethodTimer.uninstall                            # remove all wrappers (methods run at full speed again)
```

`install` options:

- `strip_root: false`: keep the full namespace in labels (by default the namespace shared by all instrumented
  classes is stripped).
- `silence_sql: false`: keep the ActiveRecord logger (it's silenced by default, as logging every query distorts
  timings).

You can call `install` several times to time a few unrelated classes together. To profile a different piece of
code in the same session, `uninstall` first, so the previous classes stop paying the per-call cost and don't show
up in the next report. (`run` already clears the numbers from the previous run.)

### Example: plain Ruby

A CSV export of 50,000 orders, each with 5 items:

```ruby
require 'csv'
require 'method_timer'

module Shop
  Order = Struct.new(:id, :customer, :items)
  Item = Struct.new(:name, :price, :quantity)

  class PriceCalculator
    TAX = 0.23

    def total(order) = order.items.sum { |item| line_total(item) }

    private

    def line_total(item) = (item.price * item.quantity * (1 + TAX)).round(2)
  end

  class CsvExport
    def initialize(orders) = @orders = orders

    def call
      CSV.generate do |csv|
        csv << %w[id customer total]
        @orders.each { |order| csv << row(order) }
      end
    end

    private

    def row(order) = [order.id, order.customer.upcase, calculator.total(order)]

    def calculator = @calculator ||= PriceCalculator.new
  end
end

orders = Array.new(50_000) do |i|
  Shop::Order.new(i, "customer #{i}", Array.new(5) { |n| Shop::Item.new("item #{n}", 9.99, n + 1) })
end

MethodTimer.install(Shop)
MethodTimer.run { Shop::CsvExport.new(orders).call }
```

```
MethodTimer: instrumented 4 classes/modules under Shop (overhead 0.77µs per call).

method                      self(ruby)  self(sql)   self(gc)      total      calls  sql calls       allocs
-----------------------------------------------------------------------------------------------------------
PriceCalculator#line_total    0.36301s   0.00000s   0.00000s   0.42104s     250000          0           12
PriceCalculator#total         0.21378s   0.00000s   0.00000s   0.64071s      50000          0            9
CsvExport#row                 0.15167s   0.00000s   0.00000s   0.81289s      50000          0       150014
CsvExport#call                0.11139s   0.00000s   0.00000s   0.92428s          1          0       250123
Item#quantity                 0.03049s   0.00000s   0.00000s   0.03049s     250000          0            2
Item#price                    0.02753s   0.00000s   0.00000s   0.02753s     250000          0            2
CsvExport#calculator          0.00823s   0.00000s   0.00000s   0.00823s      50000          0            6
Order#id                      0.00656s   0.00000s   0.00000s   0.00656s      50000          0            2
Order#items                   0.00590s   0.00000s   0.00000s   0.00590s      50000          0            2
Order#customer                0.00572s   0.00000s   0.00000s   0.00572s      50000          0            2
-----------------------------------------------------------------------------------------------------------
TOTAL (wall time of run block)                                                    0.92429s
  of which captured (sum of self ruby)            0.92428s
  of which SQL (sum of self sql / calls)                     0.00000s                                    0
  of which GC (sum of self gc)                                          0.00000s
  of which instrumentation overhead (estimated)   0.80849s  (1050002 calls x 0.77µs, counted in callers' self)
  total allocations (sum of self allocs)                                                            400176
```

Two things to notice:

- `Struct` accessors are real methods, so they're timed too. `allocs` shows where objects are created:
  `CsvExport#row` allocates 3 per call, `PriceCalculator` almost nothing.
- The overhead line says 0.81 s of the 0.92 s is the profiler itself: a million calls to tiny methods. When that
  happens, instrument only the classes you care about:

```ruby
MethodTimer.install(Shop::CsvExport)
MethodTimer.install(Shop::PriceCalculator)
MethodTimer.run { Shop::CsvExport.new(orders).call }
# 400,002 instrumented calls instead of 1,050,002; wall time 0.42 s instead of 0.92 s
```

### Example: a Rails model and service

In `rails console`, SQL time and query counts are filled in from ActiveRecord's notifications:

```ruby
MethodTimer.install(Invoice)   # an ActiveRecord model
MethodTimer.install(Billing)   # a namespace of service objects, e.g. Billing::MonthlyRun
MethodTimer.run { Billing::MonthlyRun.new(month: Date.current).call }
```

`self(sql)` and `sql calls` show which method ran the queries (cached queries are skipped), so an N+1 stands out as
a method with as many `sql calls` as `calls`. Association readers are included (Rails defines them in a named
`GeneratedAssociationMethods` module), e.g. loading 3 records and calling `download.template` on each:

```
Download::GeneratedAssociationMethods#template      3 calls      3 sql calls
```

Attribute readers (`invoice.amount`) aren't timed: Rails defines them lazily on first use, after `install` ran.

### Example: a class from another gem

```ruby
MethodTimer.install(CSV)   # CSV and everything under it (CSV::Writer, CSV::Parser, ...)
MethodTimer.run { CSV.generate { |csv| 1_000.times { |i| csv << [i, 'x'] } } }
# CSV::Writer#quote 2000 calls, CSV#<< 1000 calls, ...
```

### How long does it really take?

`bench` times a block without instrumenting anything, so it works for any code, including top-level methods and
lambdas that `install` can't reach. Use it to compare two versions:

```ruby
titles = Array.new(200_000) { |i| "Hello World #{i}!" }

MethodTimer.bench { titles.map { |t| t.downcase.gsub(/[^a-z0-9]+/, '-').delete_suffix('-') } }
# wall                     0.320s
# GC                       0.085s
# SQL                      0.000s (0 queries)
# allocations             2600038

MethodTimer.bench { titles.map { |t| t.downcase.tr('^a-z0-9', '-').squeeze('-').delete_suffix('-') } }
# wall                     0.150s
# GC                       0.043s
# SQL                      0.000s (0 queries)
# allocations             1800022

MethodTimer.bench(rss: true) { thing_to_measure } # plus memory at start, peak (sampled every second) and end
```

When comparing two versions of real code, run `bench` in a fresh process without `install`.

### What isn't timed

- Class (singleton) methods such as `Report.build`: only instance methods are wrapped. Their time counts toward
  the instance methods they call, or use `bench`.
- Top-level methods, lambdas and blocks: they aren't methods of an instrumented class.
- Methods defined after `install` (e.g. ActiveRecord attribute readers, which Rails defines on first use) and
  methods in anonymous modules: `install` wraps the methods that exist when it runs.

## Reading the report

```
method                        self(ruby)  self(sql)   self(gc)      total      calls  sql calls       allocs
------------------------------------------------------------------------------------------------------------
Supply#build_csv               36.52825s  21.26017s   4.77200s  86.66200s          1         27     52580175
Supply#build_row               22.22469s   0.00000s   0.09000s  24.03738s    4865224          0      4918938
...
------------------------------------------------------------------------------------------------------------
TOTAL (wall time of run block)                                             163.27384s
  of which captured (sum of self ruby)           101.23146s
  of which SQL (sum of self sql / calls)                    49.77568s                                    250
  of which GC (sum of self gc)                                         12.26600s
  of which instrumentation overhead (estimated)  31.75190s  (43720945 calls x 0.73µs, counted in callers' self)
  total allocations (sum of self allocs)                                                           112497459
```

- **self(ruby)**: time spent in the method's own code, excluding instrumented callees, SQL and GC.
- **self(sql)**: SQL run directly by the method (not by instrumented callees). Cached queries are skipped.
- **self(gc)**: GC pauses that started while the method itself was running. Without this column, GC time would
  land on whatever method happened to be on the stack.
- **total**: wall time including everything the method called.
- **allocs**: objects allocated directly by the method.
- **wall time of run block** = self(ruby) + self(sql) + self(gc) summed over all methods (plus anything outside
  instrumented methods). It **includes the profiler's overhead**.
- **instrumentation overhead (estimated)**: every instrumented call costs a fixed amount (measured when you call
  `install`), and that cost shows up in the callers' self(ruby). Subtract it from the wall time to estimate the
  code's real run time. A method's `total` includes the overhead of every instrumented call beneath it, so methods
  that make millions of calls look relatively more expensive than they are.

For an exact real run time, use `bench`.

## Caveats

- `uninstall` removes the timing code, but each instrumented class keeps an empty prepended module until the
  process exits (Ruby can't un-prepend). It has no per-call cost.
- Only the thread running `run` is profiled: instrumented methods called from other threads run untimed (and
  their SQL isn't counted). Run one profiled block at a time.
- With `rss: true`, memory is sampled by a child `sh` process (reading `/proc/<pid>/statm` on Linux, `ps`
  elsewhere), so sampling doesn't add allocations or GC to the profiled process.
- Lambdas and blocks aren't methods, so their time is counted in the method that calls them.
- The per-call overhead is about 0.4–0.7µs depending on the process. With tens of millions of calls, expect tens
  of seconds of overhead; the report tells you how much.

## Development

The code is split into modules extended onto `MethodTimer`, so they share its state and the generated wrappers
call `MethodTimer.enter`/`MethodTimer.leave` without an extra object per call:

- `lib/method_timer.rb`: `run` and `bench`
- `lib/method_timer/instrumenter.rb`: `install`, class discovery, labels, wrapper generation, overhead calibration
- `lib/method_timer/recorder.rb`: per-method stats (`enter`/`leave`, `stats`, `reset`)
- `lib/method_timer/reporter.rb`: report output
- `lib/method_timer/sql.rb`: SQL tracking via ActiveSupport notifications
- `lib/method_timer/memory.rb`: RSS sampling

Each module has its own spec under `spec/method_timer/`; `spec/method_timer_spec.rb` covers `run` and `bench` end to end.

```sh
bundle install
bundle exec rspec
bundle exec rubocop
bundle exec rake # both
gem build method_timer.gemspec
```

## License

MIT, see [LICENSE.txt](LICENSE.txt).
