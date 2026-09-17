# **S3 Error Counts**

## **Purpose**

By default, a failed S3 request aborts the whole benchmark phase, which is the right behavior for a functional test but not for a stress test: it stops the run at exactly the moment things get interesting, e.g. when a server starts returning 503 or 429 under load. `--s3ignoreerrors` instead counts failed requests and lets the phase run to completion, so the console, csv and json results show how much of the offered load was rejected, and of what kind.

## **How To Run**

Add `--s3ignoreerrors` to any S3 benchmark phase:

```bash
elbencho --s3endpoints http://S3SERVER --s3key S3KEY --s3secret S3SECRET \
    -w -t 16 -n 1 -N 1000 -s 1M -b 1M --s3ignoreerrors s3://mybucket
```

The AWS SDK retries a failed request on its own before elbencho ever sees it as an error, which hides most of what a saturated server is doing. To count every failed request instead of a fraction of them, disable SDK-side retries in the environment of the elbencho process:

```bash
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=1
```

In distributed mode (`--hosts`), set both variables on every service instance, not just on the master that starts the run — each service instance makes its own S3 requests and retries them independently.

A request that gets no response at all is a timeout rather than a rejection, and `--s3reqtimeout` controls how long elbencho waits before giving up on one (default: 300000 ms). Because `--timelimit` only stops a phase between requests, a run against a completely unresponsive endpoint can overrun `--timelimit` by up to one `--s3reqtimeout`, while the last round of requests times out.

## **What Is Reported**

The console shows an `Errors` row for any phase with at least one counted failure:

```
Errors           : [ total=8 http_404=8 ]
```

In distributed mode, a `Svc errors` row follows it, breaking the same total down by service instance, one entry per host and including hosts with zero errors:

```
Svc errors       : [ node001=8 node002=0 ]
```

The csv results file gets seven additional columns, always present but only filled in for a phase that had at least one counted failure:

* `errors total` - all counted failures
* `errors timeout` - failures where no response arrived before elbencho gave up (see `--s3reqtimeout`)
* `errors conn fail` - failures where no connection to the endpoint could be established
* `errors conn reset` - failures where the connection broke before or during the response
* `errors http 4xx` - failures with a 4xx HTTP status
* `errors http 5xx` - failures with a 5xx HTTP status
* `errors by kind` - every kind that occurred with its count, separated by semicolons, e.g. `http_503=40;timeout=2`

The json results file adds `errors.total` to `first_done` (the count when the fastest worker hit stonewall, only present if it is non-zero) and a fuller `errors` subtree to `last_done`, with a `total` and a `by_kind` breakdown. In distributed runs each service instance takes that snapshot when its own first thread finishes, whereas the other `first_done` counters come from the master's poll at the moment the first service reported, so the two can differ slightly under host skew and rates should use `last_done`. This is a real run against a bucket that does not exist, with `--s3ignoreerrors`, pretty-printed with `jq` (the json result file itself has one such object per line, one line per phase):

```json
{
  "phase_type": "READ",
  "phase_id": "6707c700-cbbb-4613-b210-be5c6fd5f13c",
  "iso_start_date": "2026-09-19T00:29:08.651+0000",
  "config": {
    "path_type": "bucket",
    "paths": "1",
    "hosts": "1",
    "threads": "2",
    "dirs": "1",
    "files": "4",
    "file_size": "4096",
    "block_size": "4096",
    "direct_io": "false",
    "random_offsets": "false",
    "io_depth": "1",
    "version": "3.1-12",
    "command": "..."
  },
  "first_done": {
    "elapsed_time_ms": "3",
    "entries/s": "2088",
    "iops": "2088",
    "bytes/s": "756135",
    "entries": "8",
    "ios": "8",
    "bytes": "2896",
    "cpu%": "7",
    "errors": {
      "total": "8"
    }
  },
  "last_done": {
    "elapsed_time_ms": "3",
    "entries/s": "2069",
    "iops": "2069",
    "bytes/s": "749288",
    "entries": "8",
    "ios": "8",
    "bytes": "2896",
    "cpu%": "7",
    "errors": {
      "total": "8",
      "by_kind": {
        "http_404": "8"
      }
    }
  }
}
```

`tools/elbencho-summarize-json --show-errors` adds `Errors` and `Err%` columns to its summary and details tables, computed from `last_done.errors.total` and `last_done.ios`. In the summary table, which groups multiple runs, `Errors`/`Err%` are a pooled rate for the group (sum of `errors.total` over sum of `ios`), not an average of the individual runs' rates.

## **Error Kinds**

| Kind | Meaning |
| :--- | :--- |
| `http_<code>` | The server responded with the given HTTP status code, e.g. `http_503` |
| `timeout` | No response arrived before elbencho gave up (see `--s3reqtimeout`) |
| `conn_fail` | No connection to the endpoint could be established |
| `conn_reset` | The connection broke before or during the response |
| `curl_<n>` | A libcurl error code without a more specific mapping above |
| `other` | A failure with none of the above (a build without S3_AWSCRT uses libcurl and always resolves to one of the kinds above or `curl_<n>`; a build with S3_AWSCRT matches known AWS CRT error names in the error message and falls back to `other` for anything else) |

## **Computing An Error Rate**

`errors.total / last_done.ios` is the error rate for data phases (WRITE, READ). For phases that only touch metadata (HEADOBJ, RMOBJECTS, MKBUCKETS/RMBUCKETS, the object/bucket ACL and tagging phases, LISTOBJ) use `errors.total / last_done.entries` instead, since those phases have no `ios` key. For a read/write mix (`--rwmixpct`/`--rwmixthr`), add the read-side ios: `errors.total / (last_done.ios + last_done.rwmix_read.ios)`.

For multipart uploads, a failed multipart create or complete request is counted as an error but not as an IO, so `errors.total` divided by `ios` slightly overstates the error rate and is exact only for the individual part uploads. A phase where every multipart create request failed has a non-zero `errors.total` but no `ios` key at all, since not a single part was ever attempted.

## **What The Numbers Do Not Mean**

* `entries`, `ios`, `bytes` and the derived throughput/IOPS numbers are offered load, not delivered load: they include failed operations exactly like successful ones (see "Computing An Error Rate" above for the one exception, multipart create/complete).
* With the AWS SDK's default retry behavior, a request that failed and was then retried successfully is invisible to elbencho: no error is counted, and the bytes of every attempt, not just the successful one, are counted towards `bytes`/`bytes/s`. Set `AWS_RETRY_MODE=standard` and `AWS_MAX_ATTEMPTS=1` (see "How To Run" above) to avoid this.
* Latency (`--lat`) includes failed operations along with successful ones.
* Operations still in flight when `--timelimit` fires are not counted at all, neither as an IO nor as an error. At most threads × iodepth operations can be in flight at once, so this is a small, bounded blind spot.
* The exit code stays 0 even if every single request failed, since that is the point of `--s3ignoreerrors`: check the error counts in the results, not the exit code.

## **Not Counted**

A few failures are deliberately outside this feature, either because the phase always aborts on them regardless of `--s3ignoreerrors`, or because they are not worth the bookkeeping:

* A listing failure (`--s3listobj`, or the listing step before a multi-delete) always aborts the phase, whether or not `--s3ignoreerrors` is given, so it never shows up in a completed phase's results.
* An S3 object deletion that gets a 404 always aborts the phase too, even with `--nodelerr`, which otherwise exists to tolerate exactly that response when multiple threads race to delete the same objects. With `--nodelerr`, a failed object delete other than a 404 is counted as well.
* A per-key error inside an otherwise successful multi-delete response (`DeleteObjects` with a mix of deleted and failed keys) is not inspected and not counted.
* A failed `AbortMultipartUpload` request, issued as cleanup after another request already failed, is not counted itself.
* For builds with the AWS Common Runtime (`S3_AWSCRT`), kind classification for anything other than an HTTP status or a request timeout is best-effort: it matches known CRT error names inside the error message text, which is not a documented, stable interface, unlike the numeric libcurl error codes used otherwise. An unrecognized message still counts, just as `other`.
