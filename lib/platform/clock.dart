/// A monotonic millisecond clock for everything that measures elapsed time.
///
/// Wall-clock time can jump when the network corrects it, which would read to
/// the heading fusion as a lock suddenly a minute old. The value starts at the
/// wall clock so it is never near zero - the fusion treats a zero timestamp as
/// "no update yet" - and then only moves forward.
final Stopwatch _stopwatch = Stopwatch()..start();
final int _base = DateTime.now().millisecondsSinceEpoch;

int monotonicMs() => _base + _stopwatch.elapsedMilliseconds;
